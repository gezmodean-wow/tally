-- Tally — Archive.lua
--
-- Per-month (and optionally per-week) archive storage for sealed ledger
-- entries. See TLY-51 for the locked design spec.
--
-- ============================================================================
-- Storage layout (multi-SV)
-- ============================================================================
--
-- alpha16 splits archives across multiple SavedVariables files. Each
-- archive lives in its own slot global (TallyA001 .. TallyA060), and
-- because each SV file is its own Lua chunk, each slot's contents only
-- contributes to that file's constant pool — sidesteps the alpha13
-- chunk-cap (262,144 unique constants) overflow that motivated the
-- alpha14 LibSerialize+LibDeflate compression. With slots, we can
-- store entries as raw Lua tables (no serialise / no compress) and
-- archive writes become near-instant table assignments instead of
-- multi-second serialise+compress cycles.
--
-- Per-slot shape (set by Save):
--   _G[TallyA<NNN>] = {
--     key       = "2025-12-p1" | "2025-12" | ...,
--     entries   = { ... raw entry tables ... },
--     byId      = { [id] = true, ... },
--     count, fromTs, toTs, schemaVer, savedAt,
--   }
--
-- Slot allocation (small, persisted in TallyDB):
--   TallyDB.ledger.archiveSlots = { [archiveKey] = slotNum, ... }
--   TallyDB.ledger.nextSlot     = N    (high-water mark for new keys)
--   TallyDB.ledger.archiveIndex = { [archiveKey] = { itemIDs, charKeys,
--                                                     kindCounts,
--                                                     sourceCounts,
--                                                     monthlyAggregates,
--                                                     count, fromTs, toTs } }
--
-- archiveIndex stays resident in memory at all times (it's tiny relative
-- to the slot blobs) and lets the query layer answer "do I need to load
-- this archive?" without touching the slot. ClearSourceAsync uses
-- sourceCounts as a structural fast-path: archives where the cleared
-- source has 0 rows skip the load entirely; archives where the source
-- is 100% of rows get Deleted without load.
--
-- Backward compat: pre-multi-SV archive shapes (TallyDB.ledger.archives[key]
-- with rec.blob compressed/serialised) still load via Archive:Load's
-- legacy branch. They're migrated to slots on first read in the new
-- code (see migrateLegacyArchive below).

local addonName, ns = ...

local Archive = {}
ns.Archive = Archive

local LibSerialize = LibStub and LibStub("LibSerialize", true)
local LibDeflate   = LibStub and LibStub("LibDeflate", true)

-- Bumped when the entry shape on disk changes incompatibly. Slots tagged
-- with a different schemaVer return nil from Load and the caller is
-- expected to re-seal. For alpha16 there is no prior version, so this is
-- purely forward-compat.
Archive.SCHEMA_VERSION = 1

-- Number of slot SVs declared in the TOC. If we run out, Save returns
-- (false, "no free slots"). Bump in tally.toc + here together.
Archive.SLOT_COUNT = 60

-- LRU(3) cache. Cached entries point at the same table refs the slot
-- global holds, so the cache is mostly a "tracked-as-loaded" set for
-- diag purposes; reads go through it but the slot global is already in
-- memory either way (WoW deserialised it at game startup).
local CACHE_CAP = 3
local _cache = {}
local _cacheOrder = {}

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

local function ledgerTable()
  TallyDB = TallyDB or {}
  TallyDB.ledger = TallyDB.ledger or {}
  return TallyDB.ledger
end

local function archiveSlotsTable()
  local L = ledgerTable()
  L.archiveSlots = L.archiveSlots or {}
  return L.archiveSlots
end

local function indexTable()
  local L = ledgerTable()
  L.archiveIndex = L.archiveIndex or {}
  return L.archiveIndex
end

local function legacyArchivesTable()
  local L = ledgerTable()
  return L.archives  -- nil if never populated; that's fine
end

local function slotGlobalName(slotNum)
  return string.format("TallyA%03d", slotNum)
end

-- Resolve archiveKey -> slot number, allocating a new slot if needed.
-- Returns (slotNum, globalName) on success, (nil, errMsg) if all slots
-- are occupied.
local function resolveSlot(key)
  local slots = archiveSlotsTable()
  local existing = slots[key]
  if existing then return existing, slotGlobalName(existing) end

  local L = ledgerTable()
  L.nextSlot = L.nextSlot or 0
  if L.nextSlot >= Archive.SLOT_COUNT then
    return nil, "no free archive slots — bump SLOT_COUNT in tally.toc + Archive.lua"
  end
  L.nextSlot = L.nextSlot + 1
  slots[key] = L.nextSlot
  return L.nextSlot, slotGlobalName(L.nextSlot)
end

local function getSlotGlobal(key)
  local slot = archiveSlotsTable()[key]
  if not slot then return nil end
  return _G[slotGlobalName(slot)], slot
end

local function clearSlotGlobal(slotNum)
  _G[slotGlobalName(slotNum)] = nil
end

-- ============================================================================
-- Index computation
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

-- Backfill sourceCounts on legacy archiveIndex entries that predate the
-- sourceCounts addition. Idempotent walk over the loaded entries.
local function backfillSourceCounts(key, entries)
  local idx = indexTable()[key]
  if not idx or idx.sourceCounts then return end
  local sourceCounts = {}
  for _, e in ipairs(entries) do
    if e.source then sourceCounts[e.source] = (sourceCounts[e.source] or 0) + 1 end
  end
  idx.sourceCounts = sourceCounts
end

-- ============================================================================
-- Legacy archive migration (current-branch blob shape -> slot shape)
-- ============================================================================
--
-- Pre-multi-SV archives lived as TallyDB.ledger.archives[key] = { blob,
-- count, ... }. On first read in the multi-SV code we deserialise the
-- blob (decompress if compressed) and assign the resulting entries to
-- a freshly-allocated slot. The TallyDB.ledger.archives entry gets
-- removed once the slot lands so the next save doesn't have to migrate
-- it again. archiveIndex stays untouched (already keyed correctly).

local function migrateLegacyArchive(key, legacyRec)
  if not LibSerialize then return nil end
  if not legacyRec or not legacyRec.blob then return nil end

  -- Pre-existing compressed archives need LibDeflate; uncompressed
  -- branches that briefly shipped with rec.compressed = false skip the
  -- decompress.
  local stream = legacyRec.blob
  if legacyRec.compressed ~= false then
    if not LibDeflate then return nil end
    stream = LibDeflate:DecompressDeflate(legacyRec.blob)
    if not stream then return nil end
  end
  local ok, payload = LibSerialize:Deserialize(stream)
  if not ok or type(payload) ~= "table" then return nil end

  local entries = payload.entries or {}
  local byId    = payload.byId or {}

  local slot, globalName = resolveSlot(key)
  if not slot then return nil end

  _G[globalName] = {
    key       = key,
    entries   = entries,
    byId      = byId,
    count     = #entries,
    fromTs    = legacyRec.fromTs,
    toTs      = legacyRec.toTs,
    schemaVer = Archive.SCHEMA_VERSION,
    savedAt   = legacyRec.savedAt or time(),
  }

  -- Drop the legacy entry. Index entry is preserved (already populated;
  -- backfill sourceCounts now if it wasn't).
  local L = ledgerTable()
  if L.archives then L.archives[key] = nil end
  backfillSourceCounts(key, entries)

  return _G[globalName]
end

-- Walk every legacy archive and migrate to slots in one pass. Called by
-- Ledger:loadFromDisk on first multi-SV login. Synchronous; per-archive
-- cost is one decompress + deserialise (the same cost that Compare /
-- Lifecycle would have paid lazily). For zpectre-scale ledgers this is
-- the once-only pain point of the multi-SV migration.
function Archive:MigrateAllLegacy()
  local legacy = legacyArchivesTable()
  if not legacy then return 0 end
  local count = 0
  -- Sort keys so slots get allocated in chronological order — readable
  -- in /tally diag output.
  local keys = {}
  for k in pairs(legacy) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, key in ipairs(keys) do
    if migrateLegacyArchive(key, legacy[key]) then
      count = count + 1
    end
  end
  -- Defensive: if legacy still has entries (migration failed for some),
  -- leave them alone — they'll continue to work via the legacy Load
  -- branch below until the user resolves them manually.
  return count
end

-- ============================================================================
-- Public API — Save (synchronous, fast)
-- ============================================================================
--
-- With slots, Save is a single table assignment plus an index update.
-- No serialise step, no compress step. The async variant exists for
-- API compatibility with the chunked flush path but delegates to Save
-- since there's no per-tick yielding to do.

function Archive:Save(key, entries, opts)
  if type(key) ~= "string" or key == "" then return false, "invalid key" end
  if type(entries) ~= "table" then return false, "entries must be a table" end
  opts = opts or {}

  local byId = opts.byId
  if not byId then
    byId = {}
    for _, e in ipairs(entries) do
      if e.id then byId[e.id] = true end
    end
  end

  local slot, globalName = resolveSlot(key)
  if not slot then
    if opts.onComplete then pcall(opts.onComplete, false, 0, globalName) end
    return false, globalName  -- error message in second slot
  end

  local index = computeIndex(entries)

  _G[globalName] = {
    key       = key,
    entries   = entries,
    byId      = byId,
    count     = #entries,
    fromTs    = index.fromTs,
    toTs      = index.toTs,
    schemaVer = self.SCHEMA_VERSION,
    savedAt   = time(),
  }
  indexTable()[key] = index

  -- Drop any cache entry so subsequent reads pick up the rewrite.
  self:Unload(key)

  if opts.onComplete then pcall(opts.onComplete, true, 0) end
  return true, 0
end

-- API-compatible with the previous async signature. Now synchronous-
-- but-fast — slot writes don't need yielding.
function Archive:SaveAsync(key, entries, opts)
  return self:Save(key, entries, opts)
end

-- ============================================================================
-- Public API — Load
-- ============================================================================

function Archive:Load(key)
  if _cache[key] then
    cacheBump(key)
    return _cache[key]
  end

  -- Slot path (post-multi-SV).
  local rec, slot = getSlotGlobal(key)
  if rec and rec.entries then
    if rec.schemaVer and rec.schemaVer ~= self.SCHEMA_VERSION then return nil end
    local cached = { entries = rec.entries, byId = rec.byId or {} }
    backfillSourceCounts(key, cached.entries)
    cacheEvictOldestIfFull()
    _cache[key] = cached
    _cacheOrder[#_cacheOrder + 1] = key
    return cached
  end

  -- Legacy path: TallyDB.ledger.archives[key].blob still present.
  -- Migrate it lazily and return.
  local legacy = legacyArchivesTable()
  if legacy and legacy[key] then
    local migrated = migrateLegacyArchive(key, legacy[key])
    if migrated then
      local cached = { entries = migrated.entries, byId = migrated.byId or {} }
      cacheEvictOldestIfFull()
      _cache[key] = cached
      _cacheOrder[#_cacheOrder + 1] = key
      return cached
    end
  end

  return nil
end

-- Async variant — synchronous-but-fast for slot-resident archives. The
-- onComplete callback fires immediately. Kept for API compatibility
-- with callers that chained async Save/Load operations.
function Archive:LoadAsync(key, opts)
  opts = opts or {}
  local cached = self:Load(key)
  if opts.onComplete then pcall(opts.onComplete, cached) end
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

-- ============================================================================
-- Public API — list / metadata / delete
-- ============================================================================

function Archive:Has(key)
  if archiveSlotsTable()[key] then return true end
  local legacy = legacyArchivesTable()
  return legacy and legacy[key] ~= nil or false
end

-- Sorted ascending — keys are ISO-month strings ("2025-10") with
-- optional "-pN" or "-wN" suffix; lexicographic sort matches
-- chronological order for normal usage. Includes both slot-resident
-- and unmigrated legacy archives.
function Archive:List()
  local out = {}
  local seen = {}
  for k in pairs(archiveSlotsTable()) do
    if not seen[k] then
      seen[k] = true
      out[#out + 1] = k
    end
  end
  local legacy = legacyArchivesTable()
  if legacy then
    for k in pairs(legacy) do
      if not seen[k] then
        seen[k] = true
        out[#out + 1] = k
      end
    end
  end
  table.sort(out)
  return out
end

function Archive:GetIndex(key)
  return indexTable()[key]
end

function Archive:GetMeta(key)
  local rec, slot = getSlotGlobal(key)
  if rec then
    return {
      count     = rec.count,
      fromTs    = rec.fromTs,
      toTs      = rec.toTs,
      schemaVer = rec.schemaVer,
      savedAt   = rec.savedAt,
      slot      = slot,
    }
  end
  local legacy = legacyArchivesTable()
  local lrec = legacy and legacy[key]
  if lrec then
    return {
      count     = lrec.count,
      fromTs    = lrec.fromTs,
      toTs      = lrec.toTs,
      bytes     = lrec.bytes,
      schemaVer = lrec.schemaVer,
      savedAt   = lrec.savedAt,
      legacy    = true,
    }
  end
  return nil
end

-- Permanently remove an archive from disk + cache. Used by the
-- ClearSource and seal cleanup paths when an archive ends up empty.
-- Frees the slot for reuse by the next allocation that needs one.
function Archive:Delete(key)
  local slots = archiveSlotsTable()
  local slot = slots[key]
  if slot then
    clearSlotGlobal(slot)
    slots[key] = nil
    -- Don't decrement nextSlot — we don't reuse freed slots in Phase 1
    -- to keep allocation deterministic. Slot exhaustion is unlikely
    -- with SLOT_COUNT = 60; bump if it becomes an issue.
  end
  indexTable()[key] = nil
  local legacy = legacyArchivesTable()
  if legacy then legacy[key] = nil end
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
  local slots = archiveSlotsTable()
  local L = ledgerTable()

  local archiveCount, totalRows = 0, 0
  for key, slot in pairs(slots) do
    local rec = _G[slotGlobalName(slot)]
    if rec then
      archiveCount = archiveCount + 1
      totalRows = totalRows + (rec.count or 0)
    end
  end

  local legacyCount, legacyRows, legacyBytes = 0, 0, 0
  local legacy = legacyArchivesTable()
  if legacy then
    for _, rec in pairs(legacy) do
      legacyCount = legacyCount + 1
      legacyRows = legacyRows + (rec.count or 0)
      legacyBytes = legacyBytes + (rec.bytes or 0)
    end
  end

  return {
    libsAvailable = LibSerialize and true or false,  -- only needed for legacy reads
    archiveCount  = archiveCount,
    totalRows     = totalRows,
    cachedKeys    = self:CachedKeys(),
    cacheCap      = CACHE_CAP,
    schemaVer     = self.SCHEMA_VERSION,
    slotCount     = Archive.SLOT_COUNT,
    nextSlot      = L.nextSlot or 0,
    legacyCount   = legacyCount,
    legacyRows    = legacyRows,
    legacyBytes   = legacyBytes,
  }
end
