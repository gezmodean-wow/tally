-- Tally — Sources/FlipQueue.lua
--
-- Pluggable ledger source: imports transactions from FlipQueue's existing
-- log (`FlipQueueDB.log`) into Tally's canonical ledger. Read-only —
-- FlipQueue continues to own writes to its own log.
--
-- Each FlipQueue log entry typically maps to one ledger entry, with kind
-- determined by `auctionStatus`:
--   "sold" / "collected"  →  sale          (copper = soldPrice)
--   "expired"             →  ah-expire     (copper = 0; meta carries fee)
--   "cancelled"           →  ah-cancel     (copper = 0; meta carries fee)
--   "active"              →  skipped       (in-flight, no completed txn yet)
--
-- Entries with a non-empty `buyPrice` produce an additional `purchase` ledger
-- entry — FlipQueue tracks both the buy and the eventual sale on the same
-- log row.
--
-- Source IDs are stable hashes of (charKey, postedAt, itemKey, postedQuantity)
-- so re-imports dedupe cleanly even if FlipQueue removes/reorders entries.

local addonName, ns = ...

local FQ = {}
ns.Sources = ns.Sources or {}
ns.Sources.FlipQueue = FQ

local SOURCE_NAME = "flipqueue"

-- ============================================================================
-- Helpers
-- ============================================================================

local function isAvailable()
  return type(_G.FlipQueueDB) == "table" and type(_G.FlipQueueDB.log) == "table"
end

-- Best-effort copper conversion for FQ price strings ("12g 34s 56c") + raw numbers.
local function toCopper(value)
  if type(value) == "number" then return value end
  if type(value) ~= "string" or value == "" then return 0 end
  local n = tonumber(value)
  if n then return n end
  local g = tonumber(value:match("(%d+)%s*g")) or 0
  local s = tonumber(value:match("(%d+)%s*s")) or 0
  local c = tonumber(value:match("(%d+)%s*c")) or 0
  return g * 10000 + s * 100 + c
end

local function itemIDFromKey(itemKey)
  if type(itemKey) ~= "string" then return nil end
  local id = tonumber(itemKey:match("^(%d+);"))
  return id
end

-- Stable hash for the "row identity" portion of a FlipQueue log entry.
-- (charKey, postedAt, itemKey, postedQuantity) is sufficient — duplicates
-- on the same character at the same instant for the same item are
-- genuinely the same row.
local function rowHash(entry)
  return string.format("%s|%s|%s|%s",
    entry.charKey or "",
    tostring(entry.postedAt or 0),
    entry.itemKey or "",
    tostring(entry.postedQuantity or 0))
end

-- ============================================================================
-- Mapping
-- ============================================================================

-- Translate one FlipQueue log entry into 0-N ledger entries. Returns a list.
local function mapEntry(entry)
  local out = {}
  if type(entry) ~= "table" then return out end

  local itemKey = entry.itemKey
  local itemID = itemIDFromKey(itemKey)
  local charKey = entry.charKey or ""
  local count = entry.postedQuantity or 1
  local hash = rowHash(entry)

  local meta = {
    name = entry.name,
    icon = entry.icon,
    quality = entry.quality,
    targetRealm = entry.targetRealm,
    postedPrice = entry.postedPrice,
    expectedPrice = entry.expectedPrice,
    auctionStatus = entry.auctionStatus,
    saleOutcome = entry.saleOutcome,
    ahFee = entry.ahFee,
    totalFeesSpent = entry.totalFeesSpent,
    postAttempts = entry.postAttempts,
    postHistory = entry.postHistory,
    postedAt = entry.postedAt,
  }

  local status = entry.auctionStatus or ""

  -- Sale (or collected sale).
  if (status == "sold" or status == "collected") and entry.soldPrice then
    out[#out + 1] = {
      id = SOURCE_NAME .. ":sale:" .. hash,
      atTime = entry.soldAt or entry.postedAt or time(),
      kind = "sale",
      itemKey = itemKey,
      itemID = itemID,
      charKey = charKey,
      copper = entry.soldPrice or toCopper(entry.postedPrice or entry.expectedPrice),
      count = count,
      source = SOURCE_NAME,
      sourceId = "sale:" .. hash,
      meta = meta,
    }
  elseif status == "expired" then
    out[#out + 1] = {
      id = SOURCE_NAME .. ":expire:" .. hash,
      atTime = entry.postedAt or time(),
      kind = "ah-expire",
      itemKey = itemKey,
      itemID = itemID,
      charKey = charKey,
      copper = 0,
      count = count,
      source = SOURCE_NAME,
      sourceId = "expire:" .. hash,
      meta = meta,
    }
  elseif status == "cancelled" then
    out[#out + 1] = {
      id = SOURCE_NAME .. ":cancel:" .. hash,
      atTime = entry.postedAt or time(),
      kind = "ah-cancel",
      itemKey = itemKey,
      itemID = itemID,
      charKey = charKey,
      copper = 0,
      count = count,
      source = SOURCE_NAME,
      sourceId = "cancel:" .. hash,
      meta = meta,
    }
  end
  -- "active" entries are in-flight; no completed transaction yet, skip.

  -- Purchase: separate entry produced when buyPrice is set, regardless of
  -- the auction status. FlipQueue records the cost-basis on the same row
  -- as the eventual outcome.
  if entry.buyPrice and entry.buyPrice ~= "" and entry.buyPrice ~= 0 then
    local buyCopper = toCopper(entry.buyPrice)
    if buyCopper > 0 then
      out[#out + 1] = {
        id = SOURCE_NAME .. ":buy:" .. hash,
        atTime = entry.postedAt or time(),
        kind = "purchase",
        itemKey = itemKey,
        itemID = itemID,
        charKey = charKey,
        copper = buyCopper,
        count = count,
        source = SOURCE_NAME,
        sourceId = "buy:" .. hash,
        meta = meta,
      }
    end
  end

  return out
end

-- ============================================================================
-- Import
-- ============================================================================

-- Parse phase only — returns entries that would be inserted. Used by the
-- chunked driver (Ledger:ImportFromAllSourcesChunked) for the wizard
-- backfill flow.
local function getEntries()
  if not isAvailable() then return {}, 0 end
  local entries = {}
  for _, fqEntry in ipairs(_G.FlipQueueDB.log) do
    for _, ledgerEntry in ipairs(mapEntry(fqEntry)) do
      entries[#entries + 1] = ledgerEntry
    end
  end
  return entries, 0
end

local function importAll()
  local entries = getEntries()
  return ns.Ledger:InsertMany(entries)
end

-- ============================================================================
-- Registration
-- ============================================================================

function FQ:Register()
  if not ns.Ledger or not ns.Ledger.RegisterSource then return end
  ns.Ledger:RegisterSource(SOURCE_NAME, {
    label = "FlipQueue",
    importFn = importAll,
    getEntriesFn = getEntries,
    isAvailable = isAvailable,
  })
end

-- Exposed for testing / direct invocation.
FQ.MapEntry = mapEntry
FQ.IsAvailable = isAvailable
FQ.GetEntries = getEntries
