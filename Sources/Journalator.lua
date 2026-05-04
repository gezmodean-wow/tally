-- Tally — Sources/Journalator.lua
--
-- Read-only adapter over Journalator's archived monthly logs. Journalator
-- (https://github.com/TheMouseNest/Journalator) tracks AH activity, vendor
-- transactions, repairs, trades, mail, crafting orders, quest rewards,
-- mission rewards, loot containers, taxis, trainers, and trading post
-- spending — many of which Tally has Ledger.Kinds slots for but no
-- existing producer.
--
-- TLY-22 (Phase 1): Invoices, Failures, Vendoring, Posting, VendorRepairs,
-- Trades, BasicMailReceived, BasicMailSent feed existing kinds + the new
-- ah-deposit kind from TLY-23.
--
-- TLY-23 (Phase 2): Taxis, TrainingCosts, Questing, MissionTables,
-- LootContainers, TradingPostVendoring, CraftingOrdersPlaced, Fulfilling
-- map to the new ledger kinds added alongside this adapter.
--
-- Storage shape (Journalator):
--   _G.JOURNALATOR_ARCHIVE_TIMES   = { ts, ts, ... } sorted ascending epoch
--   Journalator.State.Archive:Open("SometimesLocked", "Logs-" .. ts, true)
--     → store table with bucket arrays (Invoices, Failures, Posting, ...)
--   Journalator.State.Logs[bucket]
--     → live current-month bucket, same row shape as archives
--
-- Each row carries: time (epoch), source = { realm, character, faction },
-- plus bucket-specific fields (itemLink, count, deposit, buyout, etc.).
--
-- Coexistence: per the TLY-19 plan, this adapter imports unconditionally.
-- Native / TSM / FlipQueue continue to fire; each source produces rows with
-- distinct ids. View-time consolidation (when the same real-world event is
-- reported by multiple sources) lives outside this adapter.

local addonName, ns = ...

local Journalator = {}
ns.Sources = ns.Sources or {}
ns.Sources.Journalator = Journalator

local SOURCE_NAME = "journalator"

-- Loss counters surfaced by /tally diag (TLY-29). Per-mapper buckets
-- aggregated under shared reasons so the diag output stays compact.
Journalator.skipCounters = {
  bad_row_or_no_time = 0,
  no_char_key = 0,
  unknown_failure_type = 0,
  unknown_vendor_type = 0,
  zero_or_missing_value = 0,
}

-- ============================================================================
-- Availability
-- ============================================================================

local function isAvailable()
  -- Journalator's saved-variable index has to exist AND its in-game state
  -- (Archive + Logs) has to be initialized. The SV-only check would let us
  -- read archived months even with Journalator disabled at runtime; we
  -- avoid that — without Archive:Open we can only access the live month.
  return type(_G.JOURNALATOR_ARCHIVE_TIMES) == "table"
     and type(_G.Journalator) == "table"
     and type(_G.Journalator.State) == "table"
     and type(_G.Journalator.State.Archive) == "table"
end

-- ============================================================================
-- Helpers
-- ============================================================================

-- Build a charKey from Journalator's row source. Mirrors Cogworks's
-- "Name-Realm" convention used everywhere else in Tally.
local function charKeyFromSource(src)
  if type(src) ~= "table" then return nil end
  local char = src.character
  local realm = src.realm
  if not char or char == "" or not realm or realm == "" then return nil end
  return char .. "-" .. realm
end

-- Resolve numeric itemID from a hyperlink or itemString. Pets and currency
-- entries return nil; downstream consumers handle nil itemID gracefully
-- (entry still records, but Research:GetRecord skips it for valuation).
local function itemIDFromLink(link)
  if type(link) ~= "string" or link == "" then return nil end
  -- Try hyperlink first: |Hitem:12345:...|h
  local id = tonumber(link:match("|Hitem:(%d+)"))
  if id then return id end
  -- Bare itemString fallback.
  return tonumber(link:match("^i:(%d+)"))
end

-- Stable per-row hash. Journalator's monitor code timestamps to second
-- precision (`time()`), and combined with the bucket + source + a
-- bucket-specific salt this is sufficient for cross-session dedupe even
-- when re-importing from archives.
local function rowHash(bucket, salt, src, t)
  local realm = (src and src.realm) or ""
  local char  = (src and src.character) or ""
  return string.format("%s|%s|%s|%s|%s",
    bucket, realm, char, tostring(t or 0), salt or "")
end

local function safeNum(n) return tonumber(n) or 0 end

-- ============================================================================
-- Per-bucket mappers
-- ============================================================================
--
-- Each mapper takes one row and returns 0..N ledger entries. Returning a
-- list (rather than a single entry) lets one Journalator row produce
-- multiple ledger rows where the semantics fan out — e.g., a successful
-- AH sale invoice writes both a `sale` and an `ah-fee`, and a posting
-- writes `ah-deposit` separate from any later sale/expire.

local function mapInvoice(row)
  -- AH mail invoice. invoiceType = "seller" (auction sold) or "buyer"
  -- (auction won). We emit:
  --   seller → sale + ah-fee (consignment)
  --   buyer  → purchase
  -- Deposit refunds on a successful sale aren't separately ledger'd here
  -- — the Posting bucket already wrote the original ah-deposit; the sale
  -- row pairs with it at view time (Lifecycle).
  local out = {}
  if type(row) ~= "table" or not row.time then
    Journalator.skipCounters.bad_row_or_no_time =
      Journalator.skipCounters.bad_row_or_no_time + 1
    return out
  end
  local charKey = charKeyFromSource(row.source)
  if not charKey then
    Journalator.skipCounters.no_char_key =
      Journalator.skipCounters.no_char_key + 1
    return out
  end
  local itemID = itemIDFromLink(row.itemLink)
  local count = safeNum(row.count) > 0 and row.count or 1
  local invoiceType = row.invoiceType or row.type
  -- %.0f for copper-bearing fields: large invoice values exceed Lua's
  -- signed-32-bit %d ceiling (~214,748g). TLY-33.
  local salt = string.format("%s|%s|%.0f|%.0f|%s",
    invoiceType or "?",
    row.itemName or "?",
    safeNum(row.value),
    safeNum(count),
    row.playerName or "")
  local hash = rowHash("Invoices", salt, row.source, row.time)
  local meta = {
    name = row.itemName,
    itemLink = row.itemLink,
    invoiceType = invoiceType,
    otherPlayer = row.playerName,
    deposit = row.deposit,
    consignment = row.consignment,
  }

  local revenue = safeNum(row.value)

  if invoiceType == "seller" or (revenue > 0 and not invoiceType) then
    out[#out + 1] = {
      id = SOURCE_NAME .. ":sale:" .. hash,
      atTime = row.time,
      kind = "sale",
      itemKey = nil,
      itemID = itemID,
      charKey = charKey,
      copper = revenue,
      count = count,
      source = SOURCE_NAME,
      sourceId = "sale:" .. hash,
      meta = meta,
    }
    if safeNum(row.consignment) > 0 then
      out[#out + 1] = {
        id = SOURCE_NAME .. ":ah-fee:" .. hash,
        atTime = row.time,
        kind = "ah-fee",
        itemID = itemID,
        charKey = charKey,
        copper = row.consignment,
        count = count,
        source = SOURCE_NAME,
        sourceId = "ah-fee:" .. hash,
        meta = meta,
      }
    end
  elseif invoiceType == "buyer" then
    out[#out + 1] = {
      id = SOURCE_NAME .. ":purchase:" .. hash,
      atTime = row.time,
      kind = "purchase",
      itemID = itemID,
      charKey = charKey,
      copper = revenue,
      count = count,
      source = SOURCE_NAME,
      sourceId = "purchase:" .. hash,
      meta = meta,
    }
  end
  return out
end

local function mapFailure(row)
  -- AH expire / cancel from mail. failedType discriminates.
  local out = {}
  if type(row) ~= "table" or not row.time then
    Journalator.skipCounters.bad_row_or_no_time =
      Journalator.skipCounters.bad_row_or_no_time + 1
    return out
  end
  local charKey = charKeyFromSource(row.source)
  if not charKey then
    Journalator.skipCounters.no_char_key =
      Journalator.skipCounters.no_char_key + 1
    return out
  end
  local kind
  if row.failedType == "expired" then kind = "ah-expire"
  elseif row.failedType == "cancelled" then kind = "ah-cancel"
  else
    -- TLY-29: route unrecognized failedType (Journalator schema addition,
    -- stale-shape archive row, etc.) to Ledger.Kinds.Unknown rather than
    -- silently dropping. Counter still increments — loss accounting is
    -- now "rows routed to Unknown" rather than "rows silently dropped."
    Journalator.skipCounters.unknown_failure_type =
      Journalator.skipCounters.unknown_failure_type + 1
    local count = safeNum(row.count) > 0 and row.count or 1
    local salt = string.format("unknown:%s|%s|%d",
      row.failedType or "(empty)", row.itemName or "?", count)
    local hash = rowHash("Failures", salt, row.source, row.time)
    local unknown = ns.Ledger:BuildUnknownEntry({
      source     = SOURCE_NAME,
      sourceId   = "Failures:" .. hash,
      atTime     = row.time,
      sourceKind = row.failedType and row.failedType ~= "" and row.failedType or "(empty)",
      charKey    = charKey,
      itemID     = itemIDFromLink(row.itemLink),
      copper     = 0,
      count      = count,
      meta       = {
        name = row.itemName,
        itemLink = row.itemLink,
        failedType = row.failedType,
        bucket = "Failures",
      },
    })
    if unknown then out[#out + 1] = unknown end
    return out
  end
  local count = safeNum(row.count) > 0 and row.count or 1
  local salt = string.format("%s|%s|%d", kind, row.itemName or "?", count)
  local hash = rowHash("Failures", salt, row.source, row.time)
  out[#out + 1] = {
    id = SOURCE_NAME .. ":" .. kind .. ":" .. hash,
    atTime = row.time,
    kind = kind,
    itemID = itemIDFromLink(row.itemLink),
    charKey = charKey,
    copper = 0,
    count = count,
    source = SOURCE_NAME,
    sourceId = kind .. ":" .. hash,
    meta = { name = row.itemName, itemLink = row.itemLink, failedType = row.failedType },
  }
  return out
end

local function mapPosting(row)
  -- AH listing event. Captures the deposit at post time. The user's net
  -- on this listing is the deposit (negative if it expires/cancels) +
  -- eventual sale value (paired at view time with an Invoices row).
  local out = {}
  if type(row) ~= "table" or not row.time then
    Journalator.skipCounters.bad_row_or_no_time =
      Journalator.skipCounters.bad_row_or_no_time + 1
    return out
  end
  local charKey = charKeyFromSource(row.source)
  if not charKey then
    Journalator.skipCounters.no_char_key =
      Journalator.skipCounters.no_char_key + 1
    return out
  end
  local count = safeNum(row.count) > 0 and row.count or 1
  local salt = string.format("post|%s|%.0f|%.0f|%.0f",
    row.itemName or "?",
    safeNum(row.buyout),
    safeNum(row.deposit),
    count)
  local hash = rowHash("Posting", salt, row.source, row.time)
  out[#out + 1] = {
    id = SOURCE_NAME .. ":ah-deposit:" .. hash,
    atTime = row.time,
    kind = "ah-deposit",
    itemID = itemIDFromLink(row.itemLink),
    charKey = charKey,
    copper = safeNum(row.deposit),
    count = count,
    source = SOURCE_NAME,
    sourceId = "ah-deposit:" .. hash,
    meta = {
      name = row.itemName,
      itemLink = row.itemLink,
      buyout = row.buyout,
      bid = row.bid,
      deposit = row.deposit,
    },
  }
  return out
end

local function mapVendoring(row)
  -- Vendor sell or buy. vendorType = "sell" / "buy". value is total copper,
  -- count is stack size.
  local out = {}
  if type(row) ~= "table" or not row.time then
    Journalator.skipCounters.bad_row_or_no_time =
      Journalator.skipCounters.bad_row_or_no_time + 1
    return out
  end
  local charKey = charKeyFromSource(row.source)
  if not charKey then
    Journalator.skipCounters.no_char_key =
      Journalator.skipCounters.no_char_key + 1
    return out
  end
  local kind
  if row.vendorType == "sell" then kind = "vendor-sell"
  elseif row.vendorType == "buy" then kind = "vendor-buy"
  else
    -- TLY-29: same pattern as mapFailure — route unrecognized vendorType
    -- to Ledger.Kinds.Unknown with the original string preserved.
    Journalator.skipCounters.unknown_vendor_type =
      Journalator.skipCounters.unknown_vendor_type + 1
    local count = safeNum(row.count) > 0 and row.count or 1
    local salt = string.format("unknown:%s|%s|%.0f|%.0f",
      row.vendorType or "(empty)", row.itemName or "?",
      safeNum(row.value), count)
    local hash = rowHash("Vendoring", salt, row.source, row.time)
    local unknown = ns.Ledger:BuildUnknownEntry({
      source     = SOURCE_NAME,
      sourceId   = "Vendoring:" .. hash,
      atTime     = row.time,
      sourceKind = row.vendorType and row.vendorType ~= "" and row.vendorType or "(empty)",
      charKey    = charKey,
      itemID     = itemIDFromLink(row.itemLink),
      copper     = safeNum(row.value),
      count      = count,
      meta       = {
        name = row.itemName,
        itemLink = row.itemLink,
        vendorType = row.vendorType,
        bucket = "Vendoring",
      },
    })
    if unknown then out[#out + 1] = unknown end
    return out
  end
  local count = safeNum(row.count) > 0 and row.count or 1
  local salt = string.format("%s|%s|%.0f|%.0f", kind, row.itemName or "?", safeNum(row.value), count)
  local hash = rowHash("Vendoring", salt, row.source, row.time)
  out[#out + 1] = {
    id = SOURCE_NAME .. ":" .. kind .. ":" .. hash,
    atTime = row.time,
    kind = kind,
    itemID = itemIDFromLink(row.itemLink),
    charKey = charKey,
    copper = safeNum(row.value),
    count = count,
    source = SOURCE_NAME,
    sourceId = kind .. ":" .. hash,
    meta = { name = row.itemName, itemLink = row.itemLink, vendorType = row.vendorType },
  }
  return out
end

local function mapVendorRepair(row)
  local out = {}
  if type(row) ~= "table" or not row.time then
    Journalator.skipCounters.bad_row_or_no_time =
      Journalator.skipCounters.bad_row_or_no_time + 1
    return out
  end
  local charKey = charKeyFromSource(row.source)
  if not charKey then
    Journalator.skipCounters.no_char_key =
      Journalator.skipCounters.no_char_key + 1
    return out
  end
  local copper = safeNum(row.copperValue or row.value)
  if copper <= 0 then return out end
  local hash = rowHash("VendorRepairs", tostring(copper), row.source, row.time)
  out[#out + 1] = {
    id = SOURCE_NAME .. ":repair:" .. hash,
    atTime = row.time,
    kind = "repair",
    charKey = charKey,
    copper = copper,
    count = 1,
    source = SOURCE_NAME,
    sourceId = "repair:" .. hash,
    meta = {},
  }
  return out
end

local function mapTrade(row)
  -- Direct trade with another player. We record one neutral row capturing
  -- gross flow in either direction; itemized fanning-out is too noisy for
  -- a ledger view and the trade meta carries the full payload for drill-down.
  local out = {}
  if type(row) ~= "table" or not row.time then
    Journalator.skipCounters.bad_row_or_no_time =
      Journalator.skipCounters.bad_row_or_no_time + 1
    return out
  end
  local charKey = charKeyFromSource(row.source)
  if not charKey then
    Journalator.skipCounters.no_char_key =
      Journalator.skipCounters.no_char_key + 1
    return out
  end
  local moneyIn = safeNum(row.moneyIn)
  local moneyOut = safeNum(row.moneyOut)
  local salt = string.format("trade|%s|%.0f|%.0f", row.recipient or row.partner or "?", moneyIn, moneyOut)
  local hash = rowHash("Trades", salt, row.source, row.time)
  out[#out + 1] = {
    id = SOURCE_NAME .. ":trade:" .. hash,
    atTime = row.time,
    kind = "trade",
    charKey = charKey,
    copper = math.max(moneyIn, moneyOut),
    count = 1,
    source = SOURCE_NAME,
    sourceId = "trade:" .. hash,
    meta = {
      partner = row.recipient or row.partner,
      moneyIn = row.moneyIn,
      moneyOut = row.moneyOut,
      itemsIn = row.itemsIn,
      itemsOut = row.itemsOut,
    },
  }
  return out
end

local function mapBasicMail(row, kind)
  -- Mail send/receive (non-AH, non-CO). Money-only mails are easy; mail
  -- with items attached records as the meta item list.
  local out = {}
  if type(row) ~= "table" or not row.time then
    Journalator.skipCounters.bad_row_or_no_time =
      Journalator.skipCounters.bad_row_or_no_time + 1
    return out
  end
  local charKey = charKeyFromSource(row.source)
  if not charKey then
    Journalator.skipCounters.no_char_key =
      Journalator.skipCounters.no_char_key + 1
    return out
  end
  local money = safeNum(row.money)
  local salt = string.format("%s|%s|%.0f", kind, row.recipient or row.sender or "?", money)
  local hash = rowHash(kind == "mail-receive" and "BasicMailReceived" or "BasicMailSent",
    salt, row.source, row.time)
  out[#out + 1] = {
    id = SOURCE_NAME .. ":" .. kind .. ":" .. hash,
    atTime = row.time,
    kind = kind,
    charKey = charKey,
    copper = money,
    count = 1,
    source = SOURCE_NAME,
    sourceId = kind .. ":" .. hash,
    meta = { recipient = row.recipient, sender = row.sender, items = row.items },
  }
  return out
end

local function mapTaxi(row)
  local out = {}
  if type(row) ~= "table" or not row.time then
    Journalator.skipCounters.bad_row_or_no_time =
      Journalator.skipCounters.bad_row_or_no_time + 1
    return out
  end
  local charKey = charKeyFromSource(row.source)
  if not charKey then
    Journalator.skipCounters.no_char_key =
      Journalator.skipCounters.no_char_key + 1
    return out
  end
  local copper = safeNum(row.copperValue or row.value)
  if copper <= 0 then return out end
  local salt = string.format("taxi|%.0f|%s", copper, row.target or row.destination or "?")
  local hash = rowHash("Taxis", salt, row.source, row.time)
  out[#out + 1] = {
    id = SOURCE_NAME .. ":taxi:" .. hash,
    atTime = row.time,
    kind = "taxi",
    charKey = charKey,
    copper = copper,
    count = 1,
    source = SOURCE_NAME,
    sourceId = "taxi:" .. hash,
    meta = { origin = row.origin, target = row.target or row.destination, zone = row.zone, map = row.map },
  }
  return out
end

local function mapTrainer(row)
  local out = {}
  if type(row) ~= "table" or not row.time then
    Journalator.skipCounters.bad_row_or_no_time =
      Journalator.skipCounters.bad_row_or_no_time + 1
    return out
  end
  local charKey = charKeyFromSource(row.source)
  if not charKey then
    Journalator.skipCounters.no_char_key =
      Journalator.skipCounters.no_char_key + 1
    return out
  end
  local copper = safeNum(row.copperValue or row.value)
  if copper <= 0 then return out end
  local hash = rowHash("TrainingCosts", tostring(copper), row.source, row.time)
  out[#out + 1] = {
    id = SOURCE_NAME .. ":trainer:" .. hash,
    atTime = row.time,
    kind = "trainer",
    charKey = charKey,
    copper = copper,
    count = 1,
    source = SOURCE_NAME,
    sourceId = "trainer:" .. hash,
    meta = {},
  }
  return out
end

local function mapQuesting(row)
  -- Quest rewards: optional copper + 0..N items + 0..N currencies. We
  -- record one quest-reward row carrying the full payload. Item-level
  -- attribution lives in meta for downstream consumers.
  local out = {}
  if type(row) ~= "table" or not row.time then
    Journalator.skipCounters.bad_row_or_no_time =
      Journalator.skipCounters.bad_row_or_no_time + 1
    return out
  end
  local charKey = charKeyFromSource(row.source)
  if not charKey then
    Journalator.skipCounters.no_char_key =
      Journalator.skipCounters.no_char_key + 1
    return out
  end
  local copper = safeNum(row.copperValue or row.money or row.value)
  local salt = string.format("quest|%s|%.0f", row.questName or row.questID or "?", copper)
  local hash = rowHash("Questing", salt, row.source, row.time)
  out[#out + 1] = {
    id = SOURCE_NAME .. ":quest-reward:" .. hash,
    atTime = row.time,
    kind = "quest-reward",
    charKey = charKey,
    copper = copper,
    count = 1,
    source = SOURCE_NAME,
    sourceId = "quest-reward:" .. hash,
    meta = {
      questName = row.questName,
      questID = row.questID,
      items = row.items or row.rewardItems,
      currencies = row.currencies or row.rewardCurrencies,
    },
  }
  return out
end

local function mapMission(row)
  local out = {}
  if type(row) ~= "table" or not row.time then
    Journalator.skipCounters.bad_row_or_no_time =
      Journalator.skipCounters.bad_row_or_no_time + 1
    return out
  end
  local charKey = charKeyFromSource(row.source)
  if not charKey then
    Journalator.skipCounters.no_char_key =
      Journalator.skipCounters.no_char_key + 1
    return out
  end
  local copper = safeNum(row.copperValue or row.money or row.value)
  local salt = string.format("mission|%s|%.0f", row.missionName or row.missionID or "?", copper)
  local hash = rowHash("MissionTables", salt, row.source, row.time)
  out[#out + 1] = {
    id = SOURCE_NAME .. ":mission:" .. hash,
    atTime = row.time,
    kind = "mission",
    charKey = charKey,
    copper = copper,
    count = 1,
    source = SOURCE_NAME,
    sourceId = "mission:" .. hash,
    meta = { missionName = row.missionName, missionID = row.missionID, rewards = row.rewards or row.items },
  }
  return out
end

local function mapLootContainer(row)
  -- Loot from containers (mailbox-bonus, world drops). copperValue +
  -- items + currencies. We emit one neutral loot row per container; the
  -- per-item attribution lives in meta.
  local out = {}
  if type(row) ~= "table" or not row.time then
    Journalator.skipCounters.bad_row_or_no_time =
      Journalator.skipCounters.bad_row_or_no_time + 1
    return out
  end
  local charKey = charKeyFromSource(row.source)
  if not charKey then
    Journalator.skipCounters.no_char_key =
      Journalator.skipCounters.no_char_key + 1
    return out
  end
  local copper = safeNum(row.copperValue or row.money or row.value)
  local salt = string.format("loot|%s|%.0f", row.sourceMob or row.sourceContainer or "?", copper)
  local hash = rowHash("LootContainers", salt, row.source, row.time)
  out[#out + 1] = {
    id = SOURCE_NAME .. ":loot:" .. hash,
    atTime = row.time,
    kind = "loot",
    charKey = charKey,
    copper = copper,
    count = 1,
    source = SOURCE_NAME,
    sourceId = "loot:" .. hash,
    meta = {
      sourceMob = row.sourceMob,
      sourceContainer = row.sourceContainer,
      items = row.items or row.contents,
      currencies = row.currencies,
    },
  }
  return out
end

local function mapTradingPost(row)
  local out = {}
  if type(row) ~= "table" or not row.time then
    Journalator.skipCounters.bad_row_or_no_time =
      Journalator.skipCounters.bad_row_or_no_time + 1
    return out
  end
  local charKey = charKeyFromSource(row.source)
  if not charKey then
    Journalator.skipCounters.no_char_key =
      Journalator.skipCounters.no_char_key + 1
    return out
  end
  local salt = string.format("tp|%s|%.0f|%.0f",
    row.itemName or "?", safeNum(row.currencyCost), safeNum(row.count))
  local hash = rowHash("TradingPostVendoring", salt, row.source, row.time)
  out[#out + 1] = {
    id = SOURCE_NAME .. ":trading-post:" .. hash,
    atTime = row.time,
    kind = "trading-post",
    itemID = itemIDFromLink(row.itemLink),
    charKey = charKey,
    copper = 0,
    count = safeNum(row.count) > 0 and row.count or 1,
    source = SOURCE_NAME,
    sourceId = "trading-post:" .. hash,
    meta = { itemName = row.itemName, itemLink = row.itemLink, currencyCost = row.currencyCost },
  }
  return out
end

local function mapCraftingOrderPlaced(row)
  local out = {}
  if type(row) ~= "table" or not row.time then
    Journalator.skipCounters.bad_row_or_no_time =
      Journalator.skipCounters.bad_row_or_no_time + 1
    return out
  end
  local charKey = charKeyFromSource(row.source)
  if not charKey then
    Journalator.skipCounters.no_char_key =
      Journalator.skipCounters.no_char_key + 1
    return out
  end
  local commission = safeNum(row.commission or row.tip)
  local salt = string.format("co-place|%s|%.0f", row.recipeName or row.itemName or "?", commission)
  local hash = rowHash("CraftingOrdersPlaced", salt, row.source, row.time)
  out[#out + 1] = {
    id = SOURCE_NAME .. ":crafting-order-placed:" .. hash,
    atTime = row.time,
    kind = "crafting-order-placed",
    itemID = itemIDFromLink(row.itemLink),
    charKey = charKey,
    copper = commission,
    count = 1,
    source = SOURCE_NAME,
    sourceId = "crafting-order-placed:" .. hash,
    meta = {
      recipeName = row.recipeName,
      itemName = row.itemName,
      reagents = row.reagents,
      commission = commission,
    },
  }
  return out
end

local function mapCraftingOrderFulfilled(row)
  local out = {}
  if type(row) ~= "table" or not row.time then
    Journalator.skipCounters.bad_row_or_no_time =
      Journalator.skipCounters.bad_row_or_no_time + 1
    return out
  end
  local charKey = charKeyFromSource(row.source)
  if not charKey then
    Journalator.skipCounters.no_char_key =
      Journalator.skipCounters.no_char_key + 1
    return out
  end
  local commission = safeNum(row.commission or row.tip)
  local salt = string.format("co-fulfill|%s|%.0f", row.itemName or row.recipeName or "?", commission)
  local hash = rowHash("Fulfilling", salt, row.source, row.time)
  out[#out + 1] = {
    id = SOURCE_NAME .. ":crafting-order-fulfilled:" .. hash,
    atTime = row.time,
    kind = "crafting-order-fulfilled",
    itemID = itemIDFromLink(row.itemLink),
    charKey = charKey,
    copper = commission,
    count = 1,
    source = SOURCE_NAME,
    sourceId = "crafting-order-fulfilled:" .. hash,
    meta = {
      recipeName = row.recipeName,
      itemName = row.itemName,
      reagentsUsed = row.reagentsUsed or row.reagents,
      commission = commission,
    },
  }
  return out
end

-- Bucket → (mapper, optional kind argument). Mappers that need a kind
-- discriminator (basic mail) wrap the call so the dispatcher signature
-- stays uniform.
local BUCKETS = {
  Invoices               = mapInvoice,
  Failures               = mapFailure,
  Posting                = mapPosting,
  Vendoring              = mapVendoring,
  VendorRepairs          = mapVendorRepair,
  Trades                 = mapTrade,
  BasicMailReceived      = function(row) return mapBasicMail(row, "mail-receive") end,
  BasicMailSent          = function(row) return mapBasicMail(row, "mail-send") end,
  Taxis                  = mapTaxi,
  TrainingCosts          = mapTrainer,
  Questing               = mapQuesting,
  MissionTables          = mapMission,
  LootContainers         = mapLootContainer,
  TradingPostVendoring   = mapTradingPost,
  CraftingOrdersPlaced   = mapCraftingOrderPlaced,
  Fulfilling             = mapCraftingOrderFulfilled,
}

-- ============================================================================
-- Store iteration
-- ============================================================================

-- Walks every available store (live + every archived month) once, applies
-- the per-bucket mapper, accumulates entries. Returns (entries, parseSkipped).
local function getEntries()
  if not isAvailable() then return {}, 0 end

  local entries = {}
  local skipped = 0

  -- Live current-month state. Journalator.State.Logs is always present
  -- when the addon is loaded; bucket arrays may be empty.
  local liveLogs = _G.Journalator and _G.Journalator.State and _G.Journalator.State.Logs or nil
  if type(liveLogs) == "table" then
    for bucket, mapper in pairs(BUCKETS) do
      local rows = liveLogs[bucket]
      if type(rows) == "table" then
        for _, row in ipairs(rows) do
          local mapped = mapper(row)
          if mapped and #mapped > 0 then
            for _, e in ipairs(mapped) do entries[#entries + 1] = e end
          else
            skipped = skipped + 1
          end
        end
      end
    end
  end

  -- Archived months. Each store opens lazily; SometimesLocked is the type
  -- name Journalator's Archivist uses (defined in their own embed).
  local archive = _G.Journalator and _G.Journalator.State and _G.Journalator.State.Archive or nil
  local times = _G.JOURNALATOR_ARCHIVE_TIMES
  local STORE_PREFIX = (_G.Journalator and _G.Journalator.Constants and _G.Journalator.Constants.STORE_PREFIX) or "Logs-"
  if archive and archive.Open and type(times) == "table" then
    for _, ts in ipairs(times) do
      local ok, store = pcall(archive.Open, archive, "SometimesLocked", STORE_PREFIX .. ts, true)
      if ok and type(store) == "table" then
        for bucket, mapper in pairs(BUCKETS) do
          local rows = store[bucket]
          if type(rows) == "table" then
            for _, row in ipairs(rows) do
              local mapped = mapper(row)
              if mapped and #mapped > 0 then
                for _, e in ipairs(mapped) do entries[#entries + 1] = e end
              else
                skipped = skipped + 1
              end
            end
          end
        end
      end
    end
  end

  return entries, skipped
end

local function importAll()
  local entries, parseSkipped = getEntries()
  local inserted, insertSkipped = ns.Ledger:InsertMany(entries)
  return inserted, (insertSkipped or 0) + (parseSkipped or 0)
end

-- ============================================================================
-- Registration
-- ============================================================================

function Journalator:Register()
  if not ns.Ledger or not ns.Ledger.RegisterSource then return end
  for k in pairs(self.skipCounters) do self.skipCounters[k] = 0 end
  ns.Ledger:RegisterSource(SOURCE_NAME, {
    label = "Journalator",
    importFn = importAll,
    getEntriesFn = getEntries,
    isAvailable = isAvailable,
  })
end

-- Exposed for testing.
Journalator.IsAvailable = isAvailable
Journalator.ImportAll = importAll
Journalator.GetEntries = getEntries
