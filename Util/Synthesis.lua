-- Tally — Util/Synthesis.lua
--
-- Sibling-source month probe + candidate discovery. This is the *parser*
-- half of the old TLY-71 synthesis flow; the archive-write half (the job
-- state machine that wrote one Archive slot per period) was retired with
-- the alpha18/19 store in TLY-78. The data spine (Spine/ParseCache.lua)
-- now owns recompute-on-parse, so nothing writes archives anymore.
--
-- What survives is the cheap coverage probe: "which months do the loaded
-- sibling adapters cover?" — useful for the future Tools/export surfaces
-- (RELEASES §8) and for any UI that wants to show the player how far back
-- their sources reach without paying a full parse.

local addonName, ns = ...
ns = ns or {}

local Synthesis = {}
ns.Synthesis = Synthesis

local listeners = {}

-- ============================================================================
-- Source helpers
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

-- Parse one source via its registered getEntriesFn (pure parse path, no
-- side effects). Returns entries, skippedCount or nil, errorString.
local function parseSource(name)
  local s = getSourceMeta(name)
  if not s or not s.getEntriesFn then return nil, "no parse path" end
  local ok, entries, parseSkipped = pcall(s.getEntriesFn)
  if not ok then return nil, tostring(entries) end
  return entries or {}, parseSkipped or 0
end

-- Bucket a source's entries by month (YYYY-MM).
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

-- Parse + bucket a source's entries by month. Returns { buckets, totalRows }
-- or { error }.
function Synthesis:GetSourceBuckets(name)
  if not isSourceAvailable(name) then
    return { error = "unavailable" }
  end
  local entries, err = parseSource(name)
  if not entries then
    return { error = err or "parse failed" }
  end
  return { buckets = bucketByMonth(entries), totalRows = #entries }
end

-- ============================================================================
-- Period probe — candidate discovery
-- ============================================================================
--
-- Uses ProbeMetadata.byMonth where available (cheap — one timestamp read
-- per row, no item-string parsing) to discover which months sibling
-- adapters cover. Falls back to "we don't know coverage" for sources
-- without a probe.

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

-- "Which periods do the loaded siblings cover?" Returns the discovered
-- periods partitioned into missing (synthesisable history) and
-- skippedCurrent (the in-progress month, which the spine serves live).
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
        if ns.Ledger:IsSourceAvailable(s.name) then
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
  local missing, skippedCurrent = {}, {}
  for k, n in pairs(coverage) do
    if k == currentMonth then
      skippedCurrent[#skippedCurrent + 1] = { key = k, rows = n }
    else
      missing[#missing + 1] = { key = k, rows = n }
    end
  end
  table.sort(missing,        function(a, b) return a.key < b.key end)
  table.sort(skippedCurrent, function(a, b) return a.key < b.key end)
  return {
    sources        = sources,
    missing        = missing,
    skippedCurrent = skippedCurrent,
  }
end

-- ============================================================================
-- Listener notification (retained so a future Tools surface can subscribe)
-- ============================================================================

function Synthesis:RegisterListener(handle, callback)
  listeners[handle] = callback
end

function Synthesis:UnregisterListener(handle)
  listeners[handle] = nil
end
