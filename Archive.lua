-- Tally — Archive.lua
--
-- Per-month (and optionally per-week) archive storage for sealed ledger
-- entries. See TLY-51 for the locked design spec.
--
-- Storage layout (TallyDB.ledger):
--   active       = <serialised+deflated blob>          -- mutable, hot path (Ledger.lua)
--   activeMeta   = { count, savedAt, ... }
--   archives     = {
--     ["2025-10"]    = { blob, count, fromTs, toTs, bytes, schemaVer, savedAt },
--     ["2025-12-w1"] = { ... },                         -- subdivided when month >50k rows
--     ...
--   }
--   archiveIndex = {
--     ["2025-10"] = { itemIDs, charKeys, kindCounts, monthlyAggregates, count, fromTs, toTs },
--     ...
--   }
--
-- Archives are write-once at seal time, read-only thereafter (until a
-- schema-version bump triggers a full rebuild). archiveIndex stays
-- resident in memory at all times — it's small (per-archive itemID set
-- + charKey set + per-kind counts + monthly aggregates) and lets the
-- query layer answer "do I need to deserialise this archive?" without
-- touching the blob.
--
-- This file is the storage primitive only. Sealing policy (when to cut
-- entries from active → archives) lives in Ledger.lua's seal path.

local addonName, ns = ...

local Archive = {}
ns.Archive = Archive

local LibSerialize = LibStub and LibStub("LibSerialize", true)
local LibDeflate   = LibStub and LibStub("LibDeflate", true)

-- Bumps when the cluster algorithm or entry shape changes in a way that
-- invalidates already-sealed archives. Load() returns nil for any
-- mismatched archive and the caller is expected to re-seal from active.
-- For alpha16 there is no prior version, so this is purely forward-compat.
Archive.SCHEMA_VERSION = 1

-- LRU(3) cache. Loaded archives stay resident until evicted; cap matches
-- the spec ("at most 3 archives held"). Cache is keyed on the same key
-- the archive uses on disk ("2025-10" / "2025-12-w1" / ...).
local CACHE_CAP = 3
local _cache = {}        -- key -> { entries, byId }
local _cacheOrder = {}   -- list of keys, oldest first

local function cacheBump(key)
  for i = #_cacheOrder, 1, -1 do
    if _cacheOrder[i] == key then
      table.remove(_cacheOrder, i)
      break
    end
  end
  _cacheOrder[#_cacheOrder + 1] = key
end

local function cacheEvictOldestIfFull()
  while #_cacheOrder >= CACHE_CAP do
    local oldest = table.remove(_cacheOrder, 1)
    if oldest then _cache[oldest] = nil end
  end
end

-- ============================================================================
-- Persistence access helpers
-- ============================================================================

local function archivesTable()
  TallyDB = TallyDB or {}
  TallyDB.ledger = TallyDB.ledger or {}
  TallyDB.ledger.archives = TallyDB.ledger.archives or {}
  return TallyDB.ledger.archives
end

local function indexTable()
  TallyDB = TallyDB or {}
  TallyDB.ledger = TallyDB.ledger or {}
  TallyDB.ledger.archiveIndex = TallyDB.ledger.archiveIndex or {}
  return TallyDB.ledger.archiveIndex
end

-- ============================================================================
-- Index computation (small, plain-table — never compressed)
-- ============================================================================

local function computeIndex(entries)
  local Ledger = ns.Ledger
  local itemIDs = {}
  local charKeys = {}
  local kindCounts = {}
  local sourceCounts = {}
  local fromTs, toTs
  local netCopper, sales, purchases = 0, 0, 0

  for _, e in ipairs(entries) do
    if e.itemID then itemIDs[e.itemID] = true end
    if e.charKey then charKeys[e.charKey] = true end
    if e.kind then kindCounts[e.kind] = (kindCounts[e.kind] or 0) + 1 end
    if e.source then sourceCounts[e.source] = (sourceCounts[e.source] or 0) + 1 end
    if e.atTime then
      if not fromTs or e.atTime < fromTs then fromTs = e.atTime end
      if not toTs or e.atTime > toTs then toTs = e.atTime end
    end
    if e.copper and Ledger then
      local sign = Ledger:KindSign(e.kind)
      if sign > 0 then
        netCopper = netCopper + e.copper
        sales = sales + 1
      elseif sign < 0 then
        netCopper = netCopper - e.copper
        purchases = purchases + 1
      end
    end
  end

  return {
    count             = #entries,
    fromTs            = fromTs,
    toTs              = toTs,
    itemIDs           = itemIDs,
    charKeys          = charKeys,
    kindCounts        = kindCounts,
    sourceCounts      = sourceCounts,
    monthlyAggregates = {
      netCopper = netCopper,
      sales     = sales,
      purchases = purchases,
    },
  }
end

-- ============================================================================
-- Public API
-- ============================================================================

function Archive:Has(key)
  return archivesTable()[key] ~= nil
end

-- Sorted ascending — keys are ISO-month strings ("2025-10") with optional
-- "-wN" suffix; lexicographic sort matches chronological order.
function Archive:List()
  local out = {}
  for k in pairs(archivesTable()) do out[#out + 1] = k end
  table.sort(out)
  return out
end

function Archive:GetIndex(key)
  return indexTable()[key]
end

function Archive:GetMeta(key)
  local rec = archivesTable()[key]
  if not rec then return nil end
  return {
    count     = rec.count,
    fromTs    = rec.fromTs,
    toTs      = rec.toTs,
    bytes     = rec.bytes,
    schemaVer = rec.schemaVer,
    savedAt   = rec.savedAt,
  }
end

-- Decompress + deserialise an archive blob. Caches in LRU. Returns
-- { entries = {...}, byId = {...} } on success, nil if the archive is
-- missing, on a schema mismatch, or if libs are unavailable.
-- Backfill sourceCounts on archiveIndex entries that predate the
-- sourceCounts addition. Cheap (one walk over the loaded entries) and
-- idempotent. After this runs once per archive, future ClearSource /
-- diag / NetWorth queries that key off sourceCounts hit the fast path.
local function backfillSourceCounts(key, entries)
  local idx = indexTable()[key]
  if not idx or idx.sourceCounts then return end
  local sourceCounts = {}
  for _, e in ipairs(entries) do
    if e.source then sourceCounts[e.source] = (sourceCounts[e.source] or 0) + 1 end
  end
  idx.sourceCounts = sourceCounts
end

function Archive:Load(key)
  if _cache[key] then
    cacheBump(key)
    return _cache[key]
  end
  if not (LibSerialize and LibDeflate) then return nil end

  local rec = archivesTable()[key]
  if not rec or not rec.blob then return nil end
  if rec.schemaVer and rec.schemaVer ~= self.SCHEMA_VERSION then return nil end

  local decompressed = LibDeflate:DecompressDeflate(rec.blob)
  if not decompressed then return nil end
  local ok, payload = LibSerialize:Deserialize(decompressed)
  if not ok or type(payload) ~= "table" then return nil end

  local cached = {
    entries = payload.entries or {},
    byId    = payload.byId or {},
  }
  backfillSourceCounts(key, cached.entries)
  cacheEvictOldestIfFull()
  _cache[key] = cached
  _cacheOrder[#_cacheOrder + 1] = key
  return cached
end

-- Async variant of Load. Decompresses synchronously (cheap relative
-- to deserialise) and then drives LibSerialize:DeserializeAsync across
-- ticks with the same 1024-item yieldCheck the SaveAsync write path
-- uses. Caller passes opts.onComplete(cachedOrNil) for the result.
--
-- For the cache-hit fast path the callback fires synchronously (no
-- extra ticks). Same LRU semantics as Load on a cache miss.
function Archive:LoadAsync(key, opts)
  opts = opts or {}
  local delaySec = opts.delaySec or 0.005

  if _cache[key] then
    cacheBump(key)
    if opts.onComplete then pcall(opts.onComplete, _cache[key]) end
    return
  end
  if not (LibSerialize and LibDeflate) then
    if opts.onComplete then pcall(opts.onComplete, nil) end
    return
  end

  local rec = archivesTable()[key]
  if not rec or not rec.blob then
    if opts.onComplete then pcall(opts.onComplete, nil) end
    return
  end
  if rec.schemaVer and rec.schemaVer ~= self.SCHEMA_VERSION then
    if opts.onComplete then pcall(opts.onComplete, nil) end
    return
  end

  local decompressed = LibDeflate:DecompressDeflate(rec.blob)
  if not decompressed then
    if opts.onComplete then pcall(opts.onComplete, nil) end
    return
  end

  local YIELD_EVERY = 1024
  local handler
  local ok, err = pcall(function()
    handler = LibSerialize:DeserializeAsync(decompressed, {
      yieldCheck = function(scratch)
        scratch.count = (scratch.count or 0) + 1
        if scratch.count >= YIELD_EVERY then
          scratch.count = 0
          return true
        end
        return false
      end,
    })
  end)
  if not ok or not handler then
    if opts.onComplete then pcall(opts.onComplete, nil) end
    return
  end

  local function step()
    local resumeOk, completed, success, payload = pcall(handler)
    if not resumeOk then
      if opts.onComplete then pcall(opts.onComplete, nil) end
      return
    end
    if not completed then
      if C_Timer and C_Timer.After then
        C_Timer.After(delaySec, step)
      else
        step()
      end
      return
    end

    if not success or type(payload) ~= "table" then
      if opts.onComplete then pcall(opts.onComplete, nil) end
      return
    end

    local cached = {
      entries = payload.entries or {},
      byId    = payload.byId or {},
    }
    backfillSourceCounts(key, cached.entries)
    cacheEvictOldestIfFull()
    _cache[key] = cached
    _cacheOrder[#_cacheOrder + 1] = key
    if opts.onComplete then pcall(opts.onComplete, cached) end
  end

  step()
end

function Archive:Unload(key)
  for i = #_cacheOrder, 1, -1 do
    if _cacheOrder[i] == key then
      table.remove(_cacheOrder, i)
      break
    end
  end
  _cache[key] = nil
end

function Archive:UnloadAll()
  _cache = {}
  _cacheOrder = {}
end

-- Serialise + compress a list of entries and write them to disk under
-- `key`. Builds and persists archiveIndex[key] from the same entries.
-- Always evicts any cached copy so subsequent reads pick up the rewrite.
--
-- opts (optional):
--   byId         pre-built byId map; computed from entries if absent
--   onComplete   function(ok, bytes) — fired after the write (synchronous
--                — see SaveAsync below for the chunked variant)
--
-- Returns (true, byteCount) on success, (false, reason) on failure.
--
-- For archives over ~5,000 rows on slower machines, the synchronous
-- serialise step can block the input thread visibly. Phase 1 callers
-- on the bulk-write path (FlushStaging, seal flush, migration flush)
-- should use SaveAsync below so the work spreads across ticks.
function Archive:Save(key, entries, opts)
  if type(key) ~= "string" or key == "" then return false, "invalid key" end
  if type(entries) ~= "table" then return false, "entries must be a table" end
  if not (LibSerialize and LibDeflate) then return false, "libs unavailable" end
  opts = opts or {}

  local byId = opts.byId
  if not byId then
    byId = {}
    for _, e in ipairs(entries) do
      if e.id then byId[e.id] = true end
    end
  end

  local serialised = LibSerialize:Serialize({ entries = entries, byId = byId })
  local compressed = LibDeflate:CompressDeflate(serialised, { level = 1 })

  local index = computeIndex(entries)

  local rec = {
    blob      = compressed,
    count     = #entries,
    fromTs    = index.fromTs,
    toTs      = index.toTs,
    bytes     = #compressed,
    schemaVer = self.SCHEMA_VERSION,
    savedAt   = time(),
  }

  archivesTable()[key] = rec
  indexTable()[key] = index

  -- Drop any cached copy so the next Load picks up the new blob.
  self:Unload(key)

  if opts.onComplete then pcall(opts.onComplete, true, rec.bytes) end
  return true, rec.bytes
end

-- Chunked variant of Save. Drives LibSerialize's async coroutine across
-- C_Timer ticks (default yields every 4096 items per the lib), then
-- runs the smaller LibDeflate compress step in one final tick. For
-- archives in the tens of thousands of rows, this keeps each tick well
-- under one frame on slower machines — the synchronous Save above
-- becomes a multi-second freeze in that range.
--
-- onComplete(ok, bytes) fires once when everything is on disk. opts.onProgress
-- (optional) fires after each async-serialise yield with the cumulative
-- string length so far (handler doesn't expose item progress directly,
-- so this is a coarse heartbeat).
function Archive:SaveAsync(key, entries, opts)
  if type(key) ~= "string" or key == "" then
    if opts and opts.onComplete then pcall(opts.onComplete, false, 0, "invalid key") end
    return
  end
  if type(entries) ~= "table" then
    if opts and opts.onComplete then pcall(opts.onComplete, false, 0, "entries must be a table") end
    return
  end
  if not (LibSerialize and LibDeflate) then
    if opts and opts.onComplete then pcall(opts.onComplete, false, 0, "libs unavailable") end
    return
  end
  opts = opts or {}
  -- delaySec defaults to 0.005 (5ms). The yieldCheck at 1024 items
  -- already keeps each tick under one frame; the inter-tick wait only
  -- needs to be large enough to let C_Timer reschedule for next frame.
  -- The previous 50ms default meant 60% of wall-clock was idle wait
  -- between active yields — fine for smoothness but minutes of total
  -- runtime on multi-archive operations.
  local delaySec = opts.delaySec or 0.005

  local byId = opts.byId
  if not byId then
    byId = {}
    for _, e in ipairs(entries) do
      if e.id then byId[e.id] = true end
    end
  end

  -- Custom yieldCheck — yield every YIELD_EVERY items rather than the
  -- lib default 4096. The default is fine on fast hardware but gives
  -- visible per-tick bumps (~100-150ms CPU per yield) on the slower
  -- machines testers report from. 1024 items per yield brings each
  -- tick under ~30ms (roughly one frame at 60fps). Trade-off: more
  -- ticks total wall-clock, smoother per-tick experience.
  local YIELD_EVERY = 1024
  local handler
  local ok, err = pcall(function()
    handler = LibSerialize:SerializeAsyncEx({
      yieldCheck = function(scratch)
        scratch.count = (scratch.count or 0) + 1
        if scratch.count >= YIELD_EVERY then
          scratch.count = 0
          return true
        end
        return false
      end,
    }, { entries = entries, byId = byId })
  end)
  if not ok or not handler then
    if opts.onComplete then pcall(opts.onComplete, false, 0, "SerializeAsync failed: " .. tostring(err)) end
    return
  end

  local function step()
    local resumeOk, completed, serialised = pcall(handler)
    if not resumeOk then
      if opts.onComplete then pcall(opts.onComplete, false, 0, "serialise resume failed: " .. tostring(completed)) end
      return
    end
    if not completed then
      if C_Timer and C_Timer.After then
        C_Timer.After(delaySec, step)
      else
        step()
      end
      return
    end

    -- Async serialise complete; do the (much smaller) compress in one
    -- final tick. For most archives compress is well under a frame.
    local compressed = LibDeflate:CompressDeflate(serialised, { level = 1 })

    local index = computeIndex(entries)
    local rec = {
      blob      = compressed,
      count     = #entries,
      fromTs    = index.fromTs,
      toTs      = index.toTs,
      bytes     = #compressed,
      schemaVer = Archive.SCHEMA_VERSION,
      savedAt   = time(),
    }

    archivesTable()[key] = rec
    indexTable()[key] = index
    Archive:Unload(key)

    if opts.onComplete then pcall(opts.onComplete, true, rec.bytes) end
  end

  step()
end

-- Permanently remove an archive from disk + cache. Intended for
-- ClearSource cleanup paths where an archive ends up empty after
-- removing all rows of a given source.
function Archive:Delete(key)
  archivesTable()[key] = nil
  indexTable()[key] = nil
  self:Unload(key)
end

function Archive:CachedKeys()
  local out = {}
  for i = 1, #_cacheOrder do out[i] = _cacheOrder[i] end
  return out
end

function Archive:CacheCap()
  return CACHE_CAP
end

-- ============================================================================
-- Diagnostic surface (consumed by /tally diag Storage section)
-- ============================================================================

function Archive:DiagInfo()
  local archives = archivesTable()
  local archiveCount, archiveBytes, totalRows = 0, 0, 0
  for _, rec in pairs(archives) do
    archiveCount = archiveCount + 1
    archiveBytes = archiveBytes + (rec.bytes or 0)
    totalRows    = totalRows + (rec.count or 0)
  end
  return {
    libsAvailable = (LibSerialize and LibDeflate) and true or false,
    archiveCount  = archiveCount,
    archiveBytes  = archiveBytes,
    totalRows     = totalRows,
    cachedKeys    = self:CachedKeys(),
    cacheCap      = CACHE_CAP,
    schemaVer     = self.SCHEMA_VERSION,
  }
end
