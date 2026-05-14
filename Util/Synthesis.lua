-- Tally — Util/Synthesis.lua
--
-- TLY-71 Flow B — on-demand period synthesis. Given a list of period keys
-- (YYYY-MM), parses each enabled sibling adapter once, buckets its entries
-- by month, then writes one Archive slot per requested period. The slot
-- pool's LRU eviction (Archive.lua) keeps the on-disk footprint bounded
-- when synthesis fills the 60-slot pool faster than the player retires
-- archives.
--
-- State machine:
--
--   idle → running ⇄ paused → done / cancelled / errored
--
-- Synthesis is much shorter than Import (one period per cycle, no inner
-- chunking) so the persistence path used by Import (TallyDB.import.pending)
-- doesn't carry over here — a session-bounded job is fine. Reopen the
-- button when ready and the player runs it again.
--
-- Source parsing is the expensive step (~2-3s for a big TSM CSV). The job
-- holds a per-source cache so a 24-month run pays the parse cost once.

local addonName, ns = ...
ns = ns or {}

local Synthesis = {}
ns.Synthesis = Synthesis

local job = nil
local listeners = {}

-- ============================================================================
-- Source helpers — mirror Util/Import.lua, kept separate so synthesis can
-- evolve its own filtering/dedup without coupling to the import driver.
-- ============================================================================

local function getSourceMeta(name)
  if not (ns.Ledger and ns.Ledger.GetSources) then return nil end
  for _, s in ipairs(ns.Ledger:GetSources()) do
    if s.name == name then return s end
  end
  return nil
end

local function isSourceAvailable(name)
  return ns.Ledger and ns.Ledger.IsSourceAvailable and ns.Ledger:IsSourceAvailable(name)
end

local function parseSource(name)
  local s = getSourceMeta(name)
  if not s or not s.getEntriesFn then return nil, "no chunked path" end
  local ok, entries, parseSkipped = pcall(s.getEntriesFn)
  if not ok then return nil, tostring(entries) end
  return entries or {}, parseSkipped or 0
end

-- Bucket a source's entries by month. Called once per source per job.
local function bucketByMonth(entries)
  local buckets = {}
  for _, e in ipairs(entries) do
    if e and e.atTime then
      local key = date("%Y-%m", e.atTime)
      local bucket = buckets[key]
      if not bucket then
        bucket = {}
        buckets[key] = bucket
      end
      bucket[#bucket + 1] = e
    end
  end
  return buckets
end

-- Pull the cached month-bucket map for a source, parsing + bucketing on the
-- first request. Errors record a one-shot adapter-level note on the job
-- and skip that source for the rest of the run.
local function getSourceBuckets(j, name)
  local entry = j.sourceCache[name]
  if entry then return entry end
  if not isSourceAvailable(name) then
    j.sourceCache[name] = { error = "unavailable" }
    return j.sourceCache[name]
  end
  local entries, err = parseSource(name)
  if not entries then
    j.sourceCache[name] = { error = err or "parse failed" }
    return j.sourceCache[name]
  end
  local buckets = bucketByMonth(entries)
  j.sourceCache[name] = { buckets = buckets, totalRows = #entries }
  return j.sourceCache[name]
end

-- ============================================================================
-- Period probe — candidate discovery
-- ============================================================================
--
-- Uses ProbeMetadata.byMonth where available (cheap — one timestamp read
-- per row, no item-string parsing) to discover which months sibling
-- adapters cover. Falls back to "we don't know coverage" for sources
-- without a probe (legacy adapters); they get parsed only at synthesis
-- time if the caller explicitly requests their periods.

local function probeSourceMonths(name)
  local s = getSourceMeta(name)
  if not s then return nil end
  -- ProbeMetadata is registered on each Source module's module table,
  -- not the Ledger-side source record. Look it up by addonName convention.
  local probe
  if name == "tsm"  and ns.Sources and ns.Sources.TSM and ns.Sources.TSM.ProbeMetadata then
    probe = ns.Sources.TSM
  elseif name == "flipqueue" and ns.Sources and ns.Sources.FlipQueue and ns.Sources.FlipQueue.ProbeMetadata then
    probe = ns.Sources.FlipQueue
  elseif name == "journalator" and ns.Sources and ns.Sources.Journalator and ns.Sources.Journalator.ProbeMetadata then
    probe = ns.Sources.Journalator
  end
  if not probe then return nil end
  local ok, result = pcall(probe.ProbeMetadata, probe)
  if not ok or type(result) ~= "table" or not result.available then return nil end
  return result.byMonth
end

-- Convenience surface for the per-page button: "what periods could a
-- synthesis job actually fill?" Returns the partition of requested-or-
-- discovered periods into already-archived vs missing vs current-month
-- (which synthesis never writes — that's the active set's job).
--
-- opts.sources — list of source names to consider. Default = all
--                user-enabled + runtime-available siblings.
function Synthesis:GetCandidates(opts)
  opts = opts or {}
  local sources = opts.sources
  if not sources then
    sources = {}
    if ns.Ledger and ns.Ledger.GetSources then
      for _, s in ipairs(ns.Ledger:GetSources()) do
        if s.name ~= "native" and ns.Ledger:IsSourceAvailable(s.name) then
          sources[#sources + 1] = s.name
        end
      end
    end
  end

  local coverage = {}      -- key -> total rows across sources (for sizing)
  for _, name in ipairs(sources) do
    local byMonth = probeSourceMonths(name)
    if byMonth then
      for k, n in pairs(byMonth) do
        coverage[k] = (coverage[k] or 0) + (n or 0)
      end
    end
  end

  local currentMonth = date("%Y-%m", time())
  local missing, existing, skippedCurrent = {}, {}, {}
  for k, n in pairs(coverage) do
    if k == currentMonth then
      skippedCurrent[#skippedCurrent + 1] = { key = k, rows = n }
    elseif ns.Archive and ns.Archive.Has and ns.Archive:Has(k) then
      existing[#existing + 1] = { key = k, rows = n }
    else
      missing[#missing + 1] = { key = k, rows = n }
    end
  end
  table.sort(missing,        function(a, b) return a.key < b.key end)
  table.sort(existing,       function(a, b) return a.key < b.key end)
  table.sort(skippedCurrent, function(a, b) return a.key < b.key end)
  return {
    sources        = sources,
    missing        = missing,
    existing       = existing,
    skippedCurrent = skippedCurrent,
  }
end

-- ============================================================================
-- Listener notification (mirrors Import — same shape so a future shared
-- "long-running job" widget could subscribe to both)
-- ============================================================================

local function fireUpdate()
  for _, cb in pairs(listeners) do
    pcall(cb, job)
  end
end

function Synthesis:RegisterListener(handle, callback)
  listeners[handle] = callback
end

function Synthesis:UnregisterListener(handle)
  listeners[handle] = nil
end

-- ============================================================================
-- Cycle driver
-- ============================================================================

local function cancelTimer()
  if job and job.timerHandle then
    job.timerHandle.fired = true
    job.timerHandle = nil
  end
end

local function scheduleNext()
  if not job or job.phase ~= "running" then return end
  if not (C_Timer and C_Timer.After) then return end
  local handle = { fired = false }
  job.timerHandle = handle
  local delay = job.config.delaySec or 0.5
  C_Timer.After(delay, function()
    if handle.fired then return end
    handle.fired = true
    if job and job.phase == "running" and job.timerHandle == handle then
      Synthesis:_step()
    end
  end)
end

-- Synthesise one period: gather rows from each source's month bucket,
-- dedupe by entry id (same shape as Archive:Save's byId map), and persist.
local function synthesisePeriod(j, key)
  local merged = {}
  local byId = {}
  local sourceBreakdown = {}
  for _, name in ipairs(j.config.sources) do
    local sc = getSourceBuckets(j, name)
    if sc.error then
      sourceBreakdown[name] = { error = sc.error }
    else
      local bucket = sc.buckets and sc.buckets[key] or {}
      local addedFromThis = 0
      for _, e in ipairs(bucket) do
        if e.id then
          if not byId[e.id] then
            byId[e.id] = true
            merged[#merged + 1] = e
            addedFromThis = addedFromThis + 1
          end
        else
          -- Entries without id can't be deduped — accept the dupe risk.
          -- The byId map stays accurate for entries that DO have ids.
          merged[#merged + 1] = e
          addedFromThis = addedFromThis + 1
        end
      end
      sourceBreakdown[name] = { rows = addedFromThis }
    end
  end
  return merged, byId, sourceBreakdown
end

function Synthesis:_step()
  if not job or job.phase ~= "running" then return end

  local key = table.remove(job.queue, 1)
  if not key then
    return Synthesis:_finish()
  end

  -- Re-check: a competing path (e.g., the import controller) may have
  -- written this period since the job was queued. Skip if so.
  if ns.Archive and ns.Archive.Has and ns.Archive:Has(key) and job.config.skipExisting ~= false then
    job.results[#job.results + 1] = { key = key, rows = 0, skipped = "already-archived" }
    if job.config.onPeriodDone then pcall(job.config.onPeriodDone, key, 0, "already-archived") end
    fireUpdate()
    if job.phase == "running" then scheduleNext() end
    return
  end

  job.currentKey = key
  fireUpdate()

  local entries, byId, breakdown = synthesisePeriod(job, key)
  if #entries == 0 then
    job.results[#job.results + 1] = { key = key, rows = 0, skipped = "no-coverage", breakdown = breakdown }
    if job.config.onPeriodDone then pcall(job.config.onPeriodDone, key, 0, "no-coverage") end
    job.currentKey = nil
    fireUpdate()
    if job.phase == "running" then scheduleNext() end
    return
  end

  local ok, errMsg = ns.Archive:Save(key, entries, { byId = byId })
  if not ok then
    job.lastError = string.format("Archive:Save failed for %s: %s", key, tostring(errMsg))
    job.phase = "errored"
    if job.config.onError then pcall(job.config.onError, key, errMsg) end
    cancelTimer()
    fireUpdate()
    return
  end

  job.results[#job.results + 1] = { key = key, rows = #entries, breakdown = breakdown }
  if not job.config.quiet and ns.Output then
    ns.Output:Success(string.format("Synthesised %s — %s rows.", key,
      (BreakUpLargeNumbers or tostring)(#entries)))
  end
  if job.config.onPeriodDone then pcall(job.config.onPeriodDone, key, #entries) end
  job.currentKey = nil
  fireUpdate()

  if job.phase == "running" then scheduleNext() end
end

function Synthesis:_finish()
  if not job then return end
  job.phase       = "done"
  job.finishedAt  = time()
  job.currentKey  = nil
  cancelTimer()
  fireUpdate()
  if job.config.onComplete then pcall(job.config.onComplete, job) end
  if not job.config.quiet and ns.Output then
    local total = 0
    for _, r in ipairs(job.results) do total = total + (r.rows or 0) end
    ns.Output:Success(string.format("Synthesis complete — %d periods, %s rows total.",
      #job.results, (BreakUpLargeNumbers or tostring)(total)))
  end
end

-- ============================================================================
-- Public control API
-- ============================================================================
--
-- opts:
--   sources       — list of source names to consider (default: all enabled
--                   + available siblings excluding native)
--   delaySec      — float between periods, default 0.5
--   skipExisting  — bool, default true (skip periods that already have
--                   archives; set false to force re-synthesis)
--   quiet         — bool (suppress per-period + completion toasts)
--   onPeriodStart — fn(key)
--   onPeriodDone  — fn(key, rowCount, skipReason?)
--   onComplete    — fn(job)
--   onError       — fn(key, errMsg)

function Synthesis:EnsurePeriods(keys, opts)
  opts = opts or {}
  if type(keys) ~= "table" or #keys == 0 then return false end
  if not (ns.Archive and ns.Archive.Save) then return false end

  -- Cancel any in-flight job. Synthesis is short-running enough that we
  -- don't queue jobs behind one another; the latest request wins.
  cancelTimer()

  local sources = opts.sources
  if not sources or #sources == 0 then
    sources = {}
    if ns.Ledger and ns.Ledger.GetSources then
      for _, s in ipairs(ns.Ledger:GetSources()) do
        if s.name ~= "native" and ns.Ledger:IsSourceAvailable(s.name) then
          sources[#sources + 1] = s.name
        end
      end
    end
  end
  if #sources == 0 then
    if ns.Output then
      ns.Output:Warn("No importable sibling sources available — nothing to synthesise from.")
    end
    return false
  end

  local currentMonth = date("%Y-%m", time())
  local queue = {}
  local seen = {}
  for _, k in ipairs(keys) do
    if type(k) == "string" and k ~= "" and not seen[k] and k ~= currentMonth then
      seen[k] = true
      queue[#queue + 1] = k
    end
  end
  table.sort(queue)
  if #queue == 0 then return false end

  job = {
    phase = "running",
    config = {
      sources       = sources,
      delaySec      = opts.delaySec or 0.5,
      skipExisting  = opts.skipExisting ~= false,
      quiet         = opts.quiet and true or false,
      onPeriodStart = opts.onPeriodStart,
      onPeriodDone  = opts.onPeriodDone,
      onComplete    = opts.onComplete,
      onError       = opts.onError,
    },
    queue       = queue,
    results     = {},
    sourceCache = {},
    currentKey  = nil,
    startedAt   = time(),
    pausedAt    = nil,
    lastError   = nil,
    timerHandle = nil,
  }
  fireUpdate()

  -- Kick off the first cycle immediately — synthesis is fast enough that
  -- the player shouldn't see a 0.5s lag before the first period appears.
  Synthesis:_step()
  return true
end

function Synthesis:Pause()
  if not job or job.phase ~= "running" then return false end
  job.phase    = "paused"
  job.pausedAt = time()
  cancelTimer()
  fireUpdate()
  return true
end

function Synthesis:Resume()
  if not job or job.phase ~= "paused" then return false end
  job.phase     = "running"
  job.pausedAt  = nil
  job.lastError = nil
  fireUpdate()
  Synthesis:_step()
  return true
end

function Synthesis:Cancel()
  if not job then return false end
  if job.phase == "done" then return false end
  job.phase = "cancelled"
  cancelTimer()
  fireUpdate()
  return true
end

function Synthesis:GetState()
  if not job then return { phase = "idle" } end
  return job
end

function Synthesis:GetTotalSynthesised()
  if not job then return 0 end
  local n = 0
  for _, r in ipairs(job.results) do n = n + (r.rows or 0) end
  return n
end
