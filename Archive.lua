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
  local fromTs, toTs
  local netCopper, sales, purchases = 0, 0, 0

  for _, e in ipairs(entries) do
    if e.itemID then itemIDs[e.itemID] = true end
    if e.charKey then charKeys[e.charKey] = true end
    if e.kind then kindCounts[e.kind] = (kindCounts[e.kind] or 0) + 1 end
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
  cacheEvictOldestIfFull()
  _cache[key] = cached
  _cacheOrder[#_cacheOrder + 1] = key
  return cached
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
--   onComplete   function(ok, bytes) — fired after the write (sync; the
--                callback is here for parity with chunked sealers)
--
-- Returns (true, byteCount) on success, (false, reason) on failure.
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
