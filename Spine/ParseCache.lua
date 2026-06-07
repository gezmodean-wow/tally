-- Tally — Spine/ParseCache.lua
--
-- Session-lifetime sibling parse cache for the projection-layer redesign
-- (TLY-79).
--
-- The data spine never stores a ledger. It recomputes the unified ledger
-- from sibling sources (TSM, FlipQueue, Journalator, the old Native
-- source) — but parsing those saved-variables is the expensive step
-- (~2-3s for a big TSM CSV). This module parses each available source
-- exactly once and caches the result in memory for the rest of the
-- session; every view recomputes its aggregates from this cache rather
-- than re-parsing. Spine/Dedup.lua + Spine/UnifiedLedger.lua sit on top.
--
-- ── Lazy, not login-eager ───────────────────────────────────────────────
-- The alpha18 rewrite existed to kill the per-login parse tax — flipper
-- testers relog 20-60× per session. An unconditional login-time parse
-- would re-create exactly that pain. So the cache is populated *on first
-- demand* (the first time a view or query needs ledger data), not at
-- PLAYER_LOGIN. A player who relogs without opening Tally pays nothing;
-- opening Tally pays one 2-3s parse, behind a progress bar, then the
-- cache serves the rest of the session. This matches the tester (toeknee)
-- acceptance condition — a 2-3s pause "when opening a detailed view" is
-- fine *if a loading bar shows*.
--
-- ── Observability ───────────────────────────────────────────────────────
-- The parse steps one source per timer tick and fires listeners around
-- each step, so UI/ParseProgress.lua (Commit 3) can render a loading bar.
-- The per-source TSM block cannot itself be chunked without rewriting the
-- adapter's parser; stepping source-by-source bounds the freeze to one
-- source at a time and gives the bar a checkpoint between each.
--
-- State (returned by GetState, consumed by the progress UI):
--   {
--     phase   = "idle" | "parsing" | "ready" | "error",
--     sources = { { name, status, count, skipped, parsedAt, error }, ... },
--     currentSource = "tsm" | nil,
--     done, total,
--     startedAt, finishedAt,
--   }

local addonName, ns = ...

ns.Spine = ns.Spine or {}

local ParseCache = {}
ns.Spine.ParseCache = ParseCache

-- Delay before a source's (blocking) parse runs, so the progress bar can
-- repaint "Parsing <source>…" first — same trick the setup wizard uses
-- for its multi-second probe. Also the gap between sources.
local STEP_DELAY = 0.05

-- cache[sourceName] = { entries = {...}, count = N, skipped = N,
--                       parsedAt = epoch, error = "..." or nil }
local cache = nil

-- Flat concatenation of every source's entries, built lazily on first
-- GetAllEntries after the parse completes; cleared on Refresh.
local allEntries = nil

local state = { phase = "idle" }

-- Bumped on every Begin/Refresh. In-flight timer callbacks capture the
-- generation they were scheduled under and bail if a newer pass has
-- started, so a Refresh mid-parse cannot leave two step chains running.
local generation = 0

local listeners = {}

-- ── Listener notification (mirrors Util/Synthesis.lua) ──────────────────

local function fireUpdate()
  for _, cb in pairs(listeners) do
    pcall(cb, state)
  end
end

function ParseCache:RegisterListener(handle, callback)
  listeners[handle] = callback
end

function ParseCache:UnregisterListener(handle)
  listeners[handle] = nil
end

-- ── Source helpers ──────────────────────────────────────────────────────

local function getSourceMeta(name)
  if not (ns.Ledger and ns.Ledger.GetSources) then return nil end
  for _, s in ipairs(ns.Ledger:GetSources()) do
    if s.name == name then return s end
  end
  return nil
end

local function isSourceAvailable(name)
  return ns.Ledger and ns.Ledger.IsSourceAvailable
     and ns.Ledger:IsSourceAvailable(name)
end

-- Parse one source via its registered getEntriesFn (the pure parse path —
-- no ledger writes). Returns entries, skippedCount or nil, errorString.
local function parseSource(name)
  local s = getSourceMeta(name)
  if not s or not s.getEntriesFn then return nil, "no parse path" end
  local ok, entries, parseSkipped = pcall(s.getEntriesFn)
  if not ok then return nil, tostring(entries) end
  return entries or {}, parseSkipped or 0
end

-- ── Enablement ──────────────────────────────────────────────────────────

-- The spine is gated by TallyDB.spine.enabled (default on, per the
-- redesign — testers should exercise it; the flag is the escape hatch).
function ParseCache:IsEnabled()
  TallyDB = TallyDB or {}
  TallyDB.spine = TallyDB.spine or {}
  if TallyDB.spine.enabled == nil then
    TallyDB.spine.enabled = true
  end
  return TallyDB.spine.enabled and true or false
end

function ParseCache:SetEnabled(on)
  TallyDB = TallyDB or {}
  TallyDB.spine = TallyDB.spine or {}
  TallyDB.spine.enabled = on and true or false
  return TallyDB.spine.enabled
end

-- ── Parse driver ────────────────────────────────────────────────────────

local function finish(phase)
  state.phase = phase or "ready"
  state.currentSource = nil
  state.finishedAt = time()
  allEntries = nil  -- rebuilt on next GetAllEntries
  fireUpdate()
  -- Invalidate the projection memo so views recompute against fresh data.
  if ns.Spine.UnifiedLedger and ns.Spine.UnifiedLedger.Invalidate then
    pcall(ns.Spine.UnifiedLedger.Invalidate, ns.Spine.UnifiedLedger)
  end
  -- Recompute the period aggregates from the freshly-parsed ledger
  -- (TLY-82). Runs after the memo invalidation so it queries fresh data.
  if ns.Spine.Aggregates and ns.Spine.Aggregates.Recompute then
    pcall(ns.Spine.Aggregates.Recompute, ns.Spine.Aggregates)
  end
end

local function step(gen)
  if gen ~= generation or state.phase ~= "parsing" then return end

  local slot = state.sources[state.done + 1]
  if not slot then
    return finish("ready")
  end

  -- Announce the source about to parse, then defer one short tick so the
  -- progress bar paints "Parsing <source>…" before the blocking parse.
  state.currentSource = slot.name
  slot.status = "parsing"
  fireUpdate()

  C_Timer.After(STEP_DELAY, function()
    if gen ~= generation or state.phase ~= "parsing" then return end
    local entries, info = parseSource(slot.name)
    if entries then
      cache[slot.name] = {
        entries  = entries,
        count    = #entries,
        skipped  = info or 0,
        parsedAt = time(),
      }
      slot.status   = "done"
      slot.count    = #entries
      slot.skipped  = info or 0
      slot.parsedAt = cache[slot.name].parsedAt
    else
      cache[slot.name] = { entries = {}, count = 0, error = info }
      slot.status = "error"
      slot.error  = info
    end
    state.done = state.done + 1
    state.currentSource = nil
    fireUpdate()

    if gen == generation and state.phase == "parsing" then
      C_Timer.After(STEP_DELAY, function() step(gen) end)
    end
  end)
end

-- Begin a parse pass. No-op if the spine is disabled, a parse is already
-- in flight, or the cache is already populated (use Refresh to re-parse).
-- Returns true if a parse was kicked off.
function ParseCache:Begin()
  if not self:IsEnabled() then return false end
  if state.phase == "parsing" then return false end
  if state.phase == "ready" then return false end
  if not (ns.Ledger and ns.Ledger.GetSources and C_Timer and C_Timer.After) then
    return false
  end

  local sources = {}
  for _, s in ipairs(ns.Ledger:GetSources()) do
    if s.getEntriesFn and isSourceAvailable(s.name) then
      sources[#sources + 1] = { name = s.name, status = "pending" }
    end
  end

  cache = {}
  allEntries = nil
  generation = generation + 1
  state = {
    phase         = "parsing",
    sources       = sources,
    currentSource = nil,
    done          = 0,
    total         = #sources,
    startedAt     = time(),
  }
  fireUpdate()

  if #sources == 0 then
    finish("ready")
    return true
  end

  step(generation)
  return true
end

-- Discard the cache and parse again from scratch — used when a player
-- knows a sibling SV changed mid-session, or from /tally spine parse.
function ParseCache:Refresh()
  cache = nil
  allEntries = nil
  state = { phase = "idle" }
  fireUpdate()
  return self:Begin()
end

-- Ensure the cache is populated: kick a parse if idle, and report whether
-- data is ready *now*. This is the lazy entry point views call before
-- reading — they show a spinner while it returns false.
function ParseCache:Ensure()
  if state.phase == "idle" then self:Begin() end
  return state.phase == "ready"
end

-- ── Reads ───────────────────────────────────────────────────────────────

function ParseCache:IsReady()
  return state.phase == "ready"
end

function ParseCache:GetState()
  return state
end

-- Cached entries for one source (empty table if absent / not yet parsed).
function ParseCache:GetEntries(sourceName)
  local c = cache and cache[sourceName]
  return c and c.entries or {}
end

-- Every cached entry across all sources, as one flat list. Built once
-- after the parse completes and reused until the next Refresh.
function ParseCache:GetAllEntries()
  if allEntries then return allEntries end
  local all = {}
  if cache then
    for _, c in pairs(cache) do
      for _, e in ipairs(c.entries) do
        all[#all + 1] = e
      end
    end
  end
  if state.phase == "ready" then
    allEntries = all  -- safe to memoize only once the parse is settled
  end
  return all
end

-- Compact summary for /tally spine and /tally diag.
function ParseCache:Summary()
  local s = {
    phase   = state.phase,
    total   = state.total or 0,
    done    = state.done or 0,
    sources = {},
  }
  if cache then
    for name, c in pairs(cache) do
      s.sources[name] = {
        count   = c.count or 0,
        skipped = c.skipped or 0,
        error   = c.error,
      }
    end
  end
  return s
end
