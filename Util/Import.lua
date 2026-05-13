-- Tally — Util/Import.lua
--
-- Manual import controller (TLY-71). Wraps Ledger:InsertManyChunkedRouted
-- in an outer cycle loop so testers get pause/resume/budget-tuning while
-- a multi-source backfill is in flight. Survives logouts via
-- TallyDB.import.pending — a paused import resumes from the same source
-- + cursor on the next session.
--
-- State machine:
--
--   idle ─Start→ configured → running ⇄ paused
--                                 │
--                                 ↓
--                              flushing ─→ done
--                                 │
--                                 ↓
--                              cancelled / errored
--
-- "configured" is transient — Start flips through it into "running" before
-- returning so the wizard's Finish handler doesn't have to call a separate
-- Resume. "paused" is reachable from PLAYER_LOGIN's RestorePending too;
-- TLY-71 explicitly chose not to auto-resume on login (testers opt in via
-- the control widget's Resume button, not the launcher).
--
-- Cycle shape: each cycle slices `budgetRows` entries from the current
-- source's parsed list and feeds them to InsertManyChunkedRouted with the
-- existing 500-row sub-chunk + 5ms gap; on slice completion, sleep
-- `delaySec`, advance cursor, repeat. Pause cancels the outer timer; the
-- inner sub-chunk chain runs to completion (max ~50ms for a 10k slice)
-- before the cycle's onDone observes the new phase and stops scheduling.
--
-- Persistence boundary — TallyDB.import.pending shape:
--   { version, phase, config, sourceQueue, current, results, startedAt,
--     pausedAt, error }
-- The current source's parsed entries list is NOT persisted (would be MB
-- for big TSM CSVs); on Resume we re-parse from the sibling SV and seek
-- to the persisted cursor. Append-only sibling logs make this safe; if
-- rows shrank since pause we restart the source from idx 0 (defensive).

local addonName, ns = ...
ns = ns or {}

local Import = {}
ns.Import = Import

local PENDING_VERSION = 1

-- Module-level controller state. Singleton — only one import at a time.
local controller = nil
local listeners = {}

-- ============================================================================
-- Source iteration helpers
-- ============================================================================

local function getSourceMeta(name)
  if not (ns.Ledger and ns.Ledger.GetSources) then return nil end
  for _, s in ipairs(ns.Ledger:GetSources()) do
    if s.name == name then return s end
  end
  return nil
end

-- Parse the source's chunked entry list. Applies window cutoff (cutoffTs is
-- nil/0 → all history). Returns (entries, parseSkipped, err).
local function parseSourceEntries(name, cutoffTs)
  local s = getSourceMeta(name)
  if not s then return nil, 0, "unknown source: " .. tostring(name) end
  if not ns.Ledger:IsSourceAvailable(name) then return nil, 0, "unavailable" end
  if not s.getEntriesFn then return nil, 0, "no chunked path" end
  local ok, entries, parseSkipped = pcall(s.getEntriesFn)
  if not ok then return nil, 0, tostring(entries) end
  entries = entries or {}
  parseSkipped = parseSkipped or 0
  if not cutoffTs or cutoffTs <= 0 then return entries, parseSkipped, nil end
  -- Window filter: drop rows older than the cutoff. Per-row cost is one
  -- compare; runs once per source on first cycle, not every cycle.
  local filtered = {}
  for i = 1, #entries do
    local e = entries[i]
    if e and (e.atTime or 0) >= cutoffTs then
      filtered[#filtered + 1] = e
    end
  end
  return filtered, parseSkipped, nil
end

-- ============================================================================
-- Listener notification
-- ============================================================================

local function fireUpdate()
  for _, cb in pairs(listeners) do
    pcall(cb, controller)
  end
end

function Import:RegisterListener(handle, callback)
  listeners[handle] = callback
end

function Import:UnregisterListener(handle)
  listeners[handle] = nil
end

-- ============================================================================
-- Persistence
-- ============================================================================

-- Snapshot the controller into a serialisable shape. entries[] is excluded
-- — re-parsed on Resume.
local function buildPending()
  if not controller then return nil end
  local pending = {
    version     = PENDING_VERSION,
    phase       = controller.phase,
    config      = controller.config,
    sourceQueue = controller.sourceQueue,
    results     = controller.results,
    startedAt   = controller.startedAt,
    pausedAt    = controller.pausedAt,
    error       = controller.lastError,
  }
  if controller.current then
    pending.current = {
      name            = controller.current.name,
      label           = controller.current.label,
      idx             = controller.current.idx,
      total           = controller.current.total,
      inserted        = controller.current.inserted,
      skipped         = controller.current.skipped,
      insertedActive  = controller.current.insertedActive,
      insertedStaging = controller.current.insertedStaging,
    }
  end
  return pending
end

local function savePending()
  TallyDB = TallyDB or {}
  if not controller then
    TallyDB.import = nil
    return
  end
  -- Terminal "done" phase clears pending — fresh slate next session.
  if controller.phase == "done" then
    TallyDB.import = nil
    return
  end
  TallyDB.import = TallyDB.import or {}
  TallyDB.import.pending = buildPending()
end

function Import:HasPending()
  return TallyDB and TallyDB.import and TallyDB.import.pending and true or false
end

function Import:GetPending()
  if self:HasPending() then return TallyDB.import.pending end
  return nil
end

-- ============================================================================
-- Timer control
-- ============================================================================
--
-- We can't cancel a C_Timer.After once scheduled. Instead each scheduled
-- callback closes over a handle table; pause flips handle.fired = true
-- which the callback checks before firing. New cycles get a new handle.

local function cancelTimer()
  if controller and controller.timerHandle then
    controller.timerHandle.fired = true
    controller.timerHandle = nil
  end
end

local function scheduleNext()
  if not controller or controller.phase ~= "running" then return end
  if not (C_Timer and C_Timer.After) then return end
  local handle = { fired = false }
  controller.timerHandle = handle
  C_Timer.After(controller.config.delaySec or 2.0, function()
    if handle.fired then return end
    handle.fired = true
    if controller and controller.phase == "running" and controller.timerHandle == handle then
      Import:_step()
    end
  end)
end

-- ============================================================================
-- Cycle driver
-- ============================================================================

-- One cycle: slice budgetRows entries from current.entries[current.idx+1..]
-- and route them through InsertManyChunkedRouted. Tail-calls _advanceSource
-- when the current source is exhausted.
function Import:_step()
  if not controller or controller.phase ~= "running" then return end

  local current = controller.current
  if not current then
    return Import:_advanceSource()
  end

  -- Lazy parse on first cycle for this source. entries[] is nil after
  -- RestorePending or when a fresh source is popped from the queue. The
  -- parse pcalls inside parseSourceEntries; on error we transition to
  -- "errored" and stop the cycle chain.
  if not current.entries then
    local parsed, parseSkipped, err = parseSourceEntries(current.name, controller.cutoffTs)
    if err then
      controller.lastError = string.format("[%s] parse failed: %s", current.name, err)
      controller.phase = "errored"
      cancelTimer()
      savePending()
      fireUpdate()
      return
    end
    current.entries = parsed
    current.parseSkipped = (current.parseSkipped or 0) + parseSkipped
    current.total = #parsed
    -- Rows shrank since the persisted cursor (sibling user cleared their
    -- log between sessions, etc.) — restart this source from scratch.
    if current.idx > current.total then current.idx = 0 end
  end

  if current.idx >= current.total then
    return Import:_advanceSource()
  end

  -- Slice budget rows from cursor. The slice copy is cheap relative to the
  -- inner walk; needed because InsertManyChunkedRouted walks #entries top
  -- to bottom and we don't want it processing already-consumed rows.
  local budget = controller.config.budgetRows or 10000
  local sliceEnd = math.min(current.idx + budget, current.total)
  local slice = {}
  for i = current.idx + 1, sliceEnd do slice[#slice + 1] = current.entries[i] end

  ns.Ledger:InsertManyChunkedRouted(slice, {
    chunkSize = 500,
    delaySec  = 0.005,
    onDone = function(inserted, skipped, insertedActive, insertedStaging)
      -- Inner chain may finish after a Pause/Cancel — phase check guards
      -- against re-scheduling in that case. The cursor advance + accounting
      -- still happens (the work was done; we shouldn't re-do it on Resume).
      if not controller then return end
      current.idx             = sliceEnd
      current.inserted        = (current.inserted or 0) + (inserted or 0)
      current.skipped         = (current.skipped or 0) + (skipped or 0)
      current.insertedActive  = (current.insertedActive or 0) + (insertedActive or 0)
      current.insertedStaging = (current.insertedStaging or 0) + (insertedStaging or 0)
      savePending()
      fireUpdate()
      if current.idx >= current.total then
        return Import:_advanceSource()
      end
      if controller.phase == "running" then scheduleNext() end
    end,
  })
end

-- Stash the just-finished source's result and pop the next one, or finish.
function Import:_advanceSource()
  if not controller then return end

  if controller.current then
    local c = controller.current
    controller.results[#controller.results + 1] = {
      source          = c.name,
      label           = c.label,
      inserted        = c.inserted or 0,
      skipped         = (c.skipped or 0) + (c.parseSkipped or 0),
      insertedActive  = c.insertedActive or 0,
      insertedStaging = c.insertedStaging or 0,
    }
    controller.current = nil
  end

  local nextName = table.remove(controller.sourceQueue, 1)
  if not nextName then
    return Import:_finish()
  end

  local meta = getSourceMeta(nextName)
  if not meta or not ns.Ledger:IsSourceAvailable(nextName) then
    controller.results[#controller.results + 1] = {
      source        = nextName,
      label         = meta and meta.label or nextName,
      skippedSource = true,
      reason        = meta and "unavailable" or "unknown",
    }
    return Import:_advanceSource()
  end

  controller.current = {
    name            = nextName,
    label           = meta.label or nextName,
    idx             = 0,
    total           = 0,
    entries         = nil,   -- parsed lazily on first _step
    inserted        = 0,
    skipped         = 0,
    insertedActive  = 0,
    insertedStaging = 0,
    parseSkipped    = 0,
  }
  savePending()
  fireUpdate()

  if controller.phase == "running" then scheduleNext() end
end

-- All sources done. Flush staging buckets to archives, then mark done +
-- clear pending. Cancel-during-flush is a no-op for v1 (the flush is
-- already short and idempotent); the phase==flushing check in onComplete
-- ensures we don't flip to "done" if the user cancelled mid-flush.
function Import:_finish()
  if not controller then return end
  controller.phase = "flushing"
  fireUpdate()
  if not (ns.Ledger and ns.Ledger.FlushStaging) then
    controller.phase = "done"
    controller.finishedAt = time()
    cancelTimer()
    if TallyDB then TallyDB.import = nil end
    fireUpdate()
    return
  end
  ns.Ledger:FlushStaging({
    delaySec = 0.005,
    onProgress = function(idx, total, key)
      if not controller then return end
      controller.flushIdx   = idx
      controller.flushTotal = total
      controller.flushKey   = key
      fireUpdate()
    end,
    onComplete = function(archivesWritten, rowsArchived)
      if not controller then return end
      if controller.phase ~= "flushing" then return end
      controller.archivesWritten = archivesWritten or 0
      controller.rowsArchived    = rowsArchived or 0
      controller.phase           = "done"
      controller.finishedAt      = time()
      cancelTimer()
      if TallyDB then TallyDB.import = nil end
      fireUpdate()
      if ns.Output then
        local totalInserted = 0
        for _, r in ipairs(controller.results) do totalInserted = totalInserted + (r.inserted or 0) end
        ns.Output:Success(string.format(
          "Backfill complete — %s rows imported across %d source%s, %d archive%s written.",
          (BreakUpLargeNumbers or tostring)(totalInserted),
          #controller.results,
          #controller.results == 1 and "" or "s",
          archivesWritten or 0,
          (archivesWritten or 0) == 1 and "" or "s"))
      end
    end,
  })
end

-- ============================================================================
-- Public control API
-- ============================================================================

-- Start a fresh import. Replaces any in-flight controller without warning;
-- callers that want to preserve a paused import should check HasPending()
-- and prompt before calling Start.
--
-- opts:
--   sources        list of source names in order of import (e.g. {"tsm","flipqueue"})
--   windowMonths   1 | 3 | 12 | 0 (all history)  — default 0
--   budgetRows     int — default 10000
--   delaySec       float — default 2.0
function Import:Start(opts)
  opts = opts or {}
  cancelTimer()
  controller = {
    phase = "configured",
    config = {
      sources      = opts.sources or {},
      windowMonths = opts.windowMonths or 0,
      budgetRows   = opts.budgetRows or 10000,
      delaySec     = opts.delaySec or 2.0,
    },
    sourceQueue = {},
    current     = nil,
    results     = {},
    startedAt   = time(),
    pausedAt    = nil,
    cutoffTs    = nil,
    lastError   = nil,
    timerHandle = nil,
  }
  for _, n in ipairs(controller.config.sources) do
    controller.sourceQueue[#controller.sourceQueue + 1] = n
  end
  if controller.config.windowMonths > 0 then
    controller.cutoffTs = time() - controller.config.windowMonths * 30 * 86400
  end
  controller.phase = "running"
  savePending()
  fireUpdate()
  Import:_advanceSource()
  return controller
end

function Import:Pause()
  if not controller or controller.phase ~= "running" then return false end
  controller.phase    = "paused"
  controller.pausedAt = time()
  cancelTimer()
  savePending()
  fireUpdate()
  return true
end

-- Resume from paused/cancelled/errored. If the controller is missing but a
-- pending blob exists, restore first then resume.
function Import:Resume()
  if not controller then
    if not self:RestorePending() then return false end
  end
  if not controller then return false end
  if controller.phase == "running" then return false end
  if controller.phase == "done" then return false end
  controller.phase     = "running"
  controller.pausedAt  = nil
  controller.lastError = nil
  savePending()
  fireUpdate()
  if not controller.current then
    Import:_advanceSource()
  else
    scheduleNext()
  end
  return true
end

-- Cancel preserves pending so Resume can pick up later — TLY-71 chose this
-- over a destructive "throw away progress" cancel because users will hit
-- the X for "I'm done with this for now," not "I never want to import."
function Import:Cancel()
  if not controller then return false end
  controller.phase = "cancelled"
  cancelTimer()
  savePending()
  fireUpdate()
  return true
end

-- Live-tunable budget/delay. Takes effect on the NEXT cycle (the in-flight
-- inner chain runs to completion at its current size).
function Import:UpdateBudget(rows, delay)
  if not controller then return false end
  if rows  and rows  > 0 then controller.config.budgetRows = math.floor(rows) end
  if delay and delay > 0 then controller.config.delaySec   = delay end
  savePending()
  fireUpdate()
  return true
end

-- Restore from TallyDB.import.pending. Always wakes in "paused" — TLY-71
-- requires explicit user opt-in via the Resume button before frame budget
-- starts being spent again.
function Import:RestorePending()
  if not (TallyDB and TallyDB.import and TallyDB.import.pending) then return false end
  local p = TallyDB.import.pending
  if p.version ~= PENDING_VERSION then
    -- Schema migration boundary; v1 discards anything we don't recognise.
    TallyDB.import = nil
    return false
  end
  cancelTimer()
  controller = {
    phase       = "paused",
    config      = p.config or { budgetRows = 10000, delaySec = 2.0, windowMonths = 0, sources = {} },
    sourceQueue = p.sourceQueue or {},
    current     = nil,
    results     = p.results or {},
    startedAt   = p.startedAt,
    pausedAt    = p.pausedAt or time(),
    cutoffTs    = nil,
    lastError   = p.error,
    timerHandle = nil,
  }
  if controller.config.windowMonths and controller.config.windowMonths > 0 then
    controller.cutoffTs = time() - controller.config.windowMonths * 30 * 86400
  end
  if p.current then
    controller.current = {
      name            = p.current.name,
      label           = p.current.label,
      idx             = p.current.idx or 0,
      total           = p.current.total or 0,
      entries         = nil,                -- re-parse on next step
      inserted        = p.current.inserted or 0,
      skipped         = p.current.skipped or 0,
      insertedActive  = p.current.insertedActive or 0,
      insertedStaging = p.current.insertedStaging or 0,
      parseSkipped    = 0,
    }
  end
  fireUpdate()
  return true
end

function Import:GetState()
  if not controller then return { phase = "idle" } end
  return controller
end

-- Total rows imported so far across results + current source.
function Import:GetTotalImported()
  if not controller then return 0 end
  local n = 0
  for _, r in ipairs(controller.results) do n = n + (r.inserted or 0) end
  if controller.current then n = n + (controller.current.inserted or 0) end
  return n
end
