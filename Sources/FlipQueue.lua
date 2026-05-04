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

-- Loss counters surfaced by /tally diag (TLY-29).
FQ.skipCounters = {
  bad_entry = 0,
  active_skipped = 0,
  unknown_status = 0,
  bad_item_key = 0,
}

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
  if type(entry) ~= "table" then
    FQ.skipCounters.bad_entry = FQ.skipCounters.bad_entry + 1
    return out
  end

  local itemKey = entry.itemKey
  local itemID = itemIDFromKey(itemKey)
  if not itemID then
    if entry.itemID then
      itemID = entry.itemID
    elseif entry.itemLink and GetItemInfoInstant then
      itemID = select(1, GetItemInfoInstant(entry.itemLink))
    end
    if not itemID then
      FQ.skipCounters.bad_item_key = FQ.skipCounters.bad_item_key + 1
    end
  end
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
  elseif status == "active" then
    -- In-flight; not a completed transaction. Counted for visibility
    -- (a user with thousands of active rows on a fresh import will
    -- want to know they're being skipped on purpose).
    FQ.skipCounters.active_skipped = FQ.skipCounters.active_skipped + 1
  elseif status ~= "" and not entry.buyPrice then
    FQ.skipCounters.unknown_status = FQ.skipCounters.unknown_status + 1
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
  for k in pairs(self.skipCounters) do self.skipCounters[k] = 0 end
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
