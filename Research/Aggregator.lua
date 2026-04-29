-- Tally — Research/Aggregator.lua
--
-- Per-item research records — a strict superset of FlipQueue's existing
-- ItemResearch record so FlipQueue's ResearchPage can swap to Tally's API
-- without restructuring its consumer code.
--
-- Tally adds:
--   record.pricing  — multi-source pricing snapshot (all available TSM sources + vendor)
--   record.valuation — net-worth contribution at the configured strategy
--   record.history  — placeholder; filled by Phase 2 pricing-history module
--   record.categories — placeholder; filled by Phase 4 ledger/categorization
--
-- When FlipQueue is installed and has a populated FlipQueueDB.log, sales /
-- failures / activeAuctions / purchases are pulled from there read-only.

local addonName, ns = ...

local Research = {}
ns.Research = Research

local CACHE_TTL = 60
local cache = {}

local PRICE_SOURCES = {
  "DBMarket",
  "DBRegionMarketAvg",
  "DBRegionSaleAvg",
  "DBHistorical",
  "DBMinBuyout",
}

-- Resolve user input into (itemKey, itemID, itemLink, isPet, isBareID).
-- Bare numeric IDs collapse to a synthetic "<id>;;" key but the caller will
-- prefer the GetItemOwnershipByID rollup so all bonus-ID variants are
-- aggregated. Links use the canonical key helper so they match the rollup
-- exactly. Pet links produce a "pet:<speciesID>" key.
local function normalizeInput(input)
  if type(input) == "number" then
    return tostring(input) .. ";;", input, nil, false, true
  end
  if type(input) ~= "string" or input == "" then return nil end

  -- Hyperlinked input (item or battlepet). Use canonical key helper so the
  -- key matches what the rollup stored.
  if input:find("|H") then
    local key = ns.Items.GetItemKey(input)
    if not key then return nil end
    if ns.Items.IsPetKey(key) then
      return key, nil, input, true, false
    end
    return key, ns.Items.GetNumericID(key), input, false, false
  end

  -- Bare numeric ID — caller aggregates across bonus-ID variants.
  if input:match("^%d+$") then
    local id = tonumber(input)
    return tostring(id) .. ";;", id, nil, false, true
  end

  -- Already canonical "id;bonus;mods" or "pet:N;..."
  if input:match("^%d+;") then
    return input, ns.Items.GetNumericID(input), nil, false, false
  end
  if input:find("^pet:") then
    return input, nil, nil, true, false
  end

  return nil
end

local function copperFromPrice(value)
  if type(value) == "number" then return value end
  if type(value) ~= "string" or value == "" then return 0 end
  -- Accept "12g 34s 56c" or a raw number
  local n = tonumber(value)
  if n then return n end
  local g = tonumber(value:match("(%d+)%s*g")) or 0
  local s = tonumber(value:match("(%d+)%s*s")) or 0
  local c = tonumber(value:match("(%d+)%s*c")) or 0
  return g * 10000 + s * 100 + c
end

-- Returns (inventory[], totalCount, saleableCount). Each inventory entry has
-- both `quantity` (total) and `saleable` so FlipQueue's existing UI keeps
-- working unchanged while Tally can render the saleable distinction.
local function buildOwnership(itemKey, itemID, isBareID)
  local rollup = ns.Inventory:Get() or {}
  local inventory = {}

  if isBareID and itemID then
    local agg, byKey = ns.Inventory:GetItemOwnershipByID(itemID)
    for charKey, counts in pairs(byKey) do
      table.insert(inventory, {
        charKey = charKey,
        quantity = counts.total,
        saleable = counts.saleable,
        locations = charKey == "Warband" and { warbank = counts.total } or {},
        lastScan = rollup.lastFullScan,
      })
    end
    return inventory, agg.total, agg.saleable
  end

  local agg, byKey = ns.Inventory:GetItemOwnership(itemKey)
  for charKey, counts in pairs(byKey) do
    local entry = (rollup.characters and rollup.characters[charKey] and rollup.characters[charKey].items
      and rollup.characters[charKey].items[itemKey])
      or (charKey == "Warband" and rollup.warband and rollup.warband.items and rollup.warband.items[itemKey])
      or nil
    table.insert(inventory, {
      charKey = charKey,
      quantity = counts.total,
      saleable = counts.saleable,
      locations = (entry and entry.locations) or (charKey == "Warband" and { warbank = counts.total } or {}),
      lastScan = rollup.lastFullScan,
    })
  end
  return inventory, agg.total, agg.saleable
end

local function buildPricing(itemID, itemKey)
  local sources = {}
  local strategy = ns.NetWorth:GetStrategy()
  if ns.Pricing:HasTSM() and type(TSM_API) == "table" and type(TSM_API.GetCustomPriceValue) == "function" then
    local itemString = "i:" .. tostring(itemID)
    if type(TSM_API.ToItemString) == "function" then
      local ok, result = pcall(TSM_API.ToItemString, itemString)
      if ok and result then itemString = result end
    end
    for _, src in ipairs(PRICE_SOURCES) do
      local ok, copper = pcall(TSM_API.GetCustomPriceValue, src, itemString)
      if ok and copper and copper > 0 then sources[src] = copper end
    end
  end
  local _, _, _, _, _, _, _, _, _, _, vendor = GetItemInfo(itemID)
  if vendor and vendor > 0 then sources.vendor = vendor end

  local unitValue = ns.Pricing:GetUnitValue(itemID, itemKey, strategy)
  return {
    strategy = strategy,
    unitValue = unitValue,
    sources = sources,
  }
end

-- Pull transaction history (sales / failures / purchases) from Tally's
-- canonical ledger. Source-agnostic — any registered adapter (FlipQueue,
-- TSM, Native, Auctionator) contributes here. The record shape preserves
-- FlipQueue's ItemResearch contract so existing consumers keep working.
local function augmentTxnsFromLedger(record, itemID)
  if not (ns.Ledger and itemID) then return end

  for _, e in ipairs(ns.Ledger:Query({ itemID = itemID })) do
    local meta = e.meta or {}
    if e.kind == "sale" then
      table.insert(record.sales, {
        soldPrice = e.copper or 0,
        postedPrice = meta.postedPrice or "",
        targetRealm = meta.targetRealm or "Unknown",
        charKey = e.charKey or "",
        soldAt = e.atTime,
        postedAt = meta.postedAt,
        quantity = e.count or 1,
        source = e.source,
      })
    elseif e.kind == "ah-expire" or e.kind == "ah-cancel" then
      table.insert(record.failures, {
        postedPrice = meta.postedPrice or "",
        targetRealm = meta.targetRealm or "Unknown",
        charKey = e.charKey or "",
        postedAt = meta.postedAt or e.atTime,
        auctionStatus = (e.kind == "ah-expire") and "expired" or "cancelled",
        saleOutcome = meta.saleOutcome,
        fee = meta.ahFee or 0,
        totalFeesSpent = meta.totalFeesSpent or 0,
        postAttempts = meta.postAttempts or 0,
        postHistory = meta.postHistory,
        source = e.source,
      })
    elseif e.kind == "purchase" then
      table.insert(record.purchases, {
        price = e.copper or 0,
        priceStr = meta.postedPrice or "",
        realm = meta.targetRealm or "Unknown",
        charKey = e.charKey or "",
        timestamp = e.atTime,
        source = e.source,
      })
    end
  end

  -- Sales summary.
  local totalRev, count = 0, 0
  for _, s in ipairs(record.sales) do
    totalRev = totalRev + (s.soldPrice or 0)
    count = count + 1
  end
  record.salesSummary = {
    count = count,
    totalRevenue = totalRev,
    avgPrice = count > 0 and math.floor(totalRev / count) or 0,
    byRealm = {},
  }
  for _, s in ipairs(record.sales) do
    local r = s.targetRealm or "Unknown"
    record.salesSummary.byRealm[r] = record.salesSummary.byRealm[r] or { count = 0, total = 0 }
    record.salesSummary.byRealm[r].count = record.salesSummary.byRealm[r].count + 1
    record.salesSummary.byRealm[r].total = record.salesSummary.byRealm[r].total + (s.soldPrice or 0)
  end

  -- Failure summary.
  local expired, cancelled, feesLost = 0, 0, 0
  for _, f in ipairs(record.failures) do
    if f.auctionStatus == "expired" then expired = expired + 1
    elseif f.auctionStatus == "cancelled" then cancelled = cancelled + 1 end
    feesLost = feesLost + (f.totalFeesSpent or f.fee or 0)
  end
  record.failureSummary = { expiredCount = expired, cancelledCount = cancelled, totalFeesLost = feesLost }
end

-- FlipQueue-specific augmentation: icon enrichment + active (in-flight)
-- auctions. Active auctions aren't ledger-shaped (they're ephemeral state,
-- not completed transactions), so they stay sourced directly from FQ.
local function augmentMetaFromFlipQueue(record, itemID, itemName)
  local fqdb = _G.FlipQueueDB
  if type(fqdb) ~= "table" or type(fqdb.log) ~= "table" then return end

  for _, entry in ipairs(fqdb.log) do
    local entryID = tonumber((entry.itemKey or ""):match("^(%d+);"))
    local matchByID = entryID and itemID and entryID == itemID
    local matchByName = itemName and entry.name and entry.name:lower() == itemName:lower()
    if matchByID or matchByName then
      if not record.icon and entry.icon then record.icon = entry.icon end
      if not record.quality and entry.quality then record.quality = entry.quality end
      if (not record.name or record.name == "") and entry.name then record.name = entry.name end

      if (entry.auctionStatus or "") == "active" then
        table.insert(record.activeAuctions, {
          postedPrice = entry.postedPrice or "",
          expectedPrice = entry.expectedPrice or "",
          targetRealm = entry.targetRealm or "Unknown",
          charKey = entry.charKey or "",
          postedAt = entry.postedAt,
          quantity = entry.postedQuantity or 1,
        })
      end
    end
  end
end

function Research:GetRecord(input, itemName, skipCache)
  local itemKey, itemID, itemLink, isPet, isBareID = normalizeInput(input)
  if not itemKey then return nil end

  if not skipCache then
    local cached = cache[itemKey]
    if cached and (time() - cached.ts) < CACHE_TTL then
      return cached.record
    end
  end

  -- Item info (for items only; pets get name from the link).
  local name, quality, icon
  if itemID then
    local n, _, q, _, _, _, _, _, _, ic = GetItemInfo(itemID)
    name, quality, icon = n, q, ic
  elseif isPet and type(input) == "string" then
    name = input:match("|h%[(.-)%]|h")
  end

  local record = {
    itemKey = itemKey,
    itemID = itemID,
    itemLink = itemLink,
    isPet = isPet or false,
    name = itemName or name or "",
    icon = icon,
    quality = quality,

    inventory = {},
    totalInventory = 0,
    saleableInventory = 0,

    sales = {},
    salesSummary = { count = 0, totalRevenue = 0, avgPrice = 0, byRealm = {} },
    failures = {},
    failureSummary = { expiredCount = 0, cancelledCount = 0, totalFeesLost = 0 },
    activeAuctions = {},
    fpDeals = {},
    purchases = {},

    pricing = nil,
    valuation = { netWorthContribution = 0, ownedWorthContribution = 0 },
    tsm = nil,           -- preserved for FlipQueue compatibility; populated below
    history = nil,       -- Tally pricing-history snapshots (populated below for items)
    categories = {},     -- Phase 4
  }

  record.inventory, record.totalInventory, record.saleableInventory = buildOwnership(itemKey, itemID, isBareID)

  -- Pets aren't priced via TSM by item-ID. Skip pricing for pets; future
  -- enhancement could integrate pet-cage market data.
  if not isPet and itemID then
    record.pricing = buildPricing(itemID, itemKey)
    record.tsm = record.pricing.sources
    record.valuation.netWorthContribution = (record.pricing.unitValue or 0) * record.saleableInventory
    record.valuation.ownedWorthContribution = (record.pricing.unitValue or 0) * record.totalInventory
  else
    record.pricing = { strategy = ns.NetWorth:GetStrategy(), unitValue = 0, sources = {} }
    record.tsm = {}
  end

  if itemID then
    augmentTxnsFromLedger(record, itemID)
    augmentMetaFromFlipQueue(record, itemID, record.name ~= "" and record.name or nil)
  end

  -- Tally pricing history: time-series snapshots under the active strategy.
  if not isPet and itemID and ns.History then
    local points = ns.History:GetItemHistory(itemID)
    local trend7d  = ns.History:GetItemTrend(itemID, 7  * 86400)
    local trend30d = ns.History:GetItemTrend(itemID, 30 * 86400)
    record.history = {
      strategy = ns.NetWorth:GetStrategy(),
      points = points,
      trend7d = trend7d,
      trend30d = trend30d,
    }
  end

  -- Inventory history: per-character total + delta over rolling windows.
  if itemID and ns.History then
    local invPoints = ns.History:GetItemInventoryHistory(itemID)
    local invTrend7d  = ns.History:GetItemInventoryTrend(itemID, 7  * 86400)
    local invTrend30d = ns.History:GetItemInventoryTrend(itemID, 30 * 86400)
    record.inventoryHistory = {
      points = invPoints,
      trend7d = invTrend7d,
      trend30d = invTrend30d,
    }
  end

  cache[itemKey] = { ts = time(), record = record }
  return record
end

function Research:Invalidate(itemKey)
  if itemKey then cache[itemKey] = nil
  else cache = {} end
end

-- Pretty-print a research record to chat. Used by the slash command.
function Research:Print(input)
  local record = self:GetRecord(input)
  if not record then
    print("|cffff4040Tally:|r couldn't resolve item.")
    return
  end
  local fmt = ns.NetWorth.FormatGold
  local prefix = "|cff7fbfffTally|r research:"
  local linkOrName = record.itemLink or record.name
    or (record.itemID and ("item:" .. record.itemID))
    or record.itemKey
  print(prefix .. " " .. linkOrName)
  if record.isPet then
    print(string.format("  Owned: %d (pets aren't priced — net-worth contribution skipped)",
      record.totalInventory))
  else
    local boundCount = record.totalInventory - record.saleableInventory
    if boundCount > 0 then
      print(string.format("  Owned: %d total, %d saleable (%d bound) — saleable worth %s @ %s",
        record.totalInventory, record.saleableInventory, boundCount,
        fmt(record.valuation.netWorthContribution), record.pricing.strategy))
    else
      print(string.format("  Owned: %d (worth %s @ %s)",
        record.totalInventory, fmt(record.valuation.netWorthContribution), record.pricing.strategy))
    end
  end
  -- Per-character/warband breakdown with per-location detail. Useful for
  -- confirming warband visibility and seeing where equipped/void/auction
  -- copies live.
  if #record.inventory > 0 then
    local LOC_ORDER = { "bags", "reagent", "bank", "mail", "equipped", "void", "auctions", "warbank" }
    local parts = {}
    for _, inv in ipairs(record.inventory) do
      local locParts = {}
      for _, loc in ipairs(LOC_ORDER) do
        local n = inv.locations and inv.locations[loc]
        if n and n > 0 then
          locParts[#locParts + 1] = loc .. " ×" .. n
        end
      end
      local label
      if inv.saleable and inv.saleable < inv.quantity then
        label = string.format("%s ×%d (%d saleable)", inv.charKey, inv.quantity, inv.saleable)
      else
        label = inv.charKey .. " ×" .. inv.quantity
      end
      if #locParts > 0 then
        parts[#parts + 1] = label .. " [" .. table.concat(locParts, ", ") .. "]"
      else
        parts[#parts + 1] = label
      end
    end
    print("  Locations: " .. table.concat(parts, ", "))
  end
  if record.pricing.sources then
    local parts = {}
    for _, src in ipairs(PRICE_SOURCES) do
      if record.pricing.sources[src] then
        parts[#parts + 1] = src .. " " .. fmt(record.pricing.sources[src])
      end
    end
    if record.pricing.sources.vendor then
      parts[#parts + 1] = "vendor " .. fmt(record.pricing.sources.vendor)
    end
    if #parts > 0 then print("  Prices: " .. table.concat(parts, " | ")) end
  end
  if record.salesSummary.count > 0 then
    print(string.format("  Sales (FlipQueue log): %d sold, %s revenue, avg %s",
      record.salesSummary.count, fmt(record.salesSummary.totalRevenue), fmt(record.salesSummary.avgPrice)))
  end
  if record.failureSummary.expiredCount + record.failureSummary.cancelledCount > 0 then
    print(string.format("  Failures: %d expired / %d cancelled, %s fees",
      record.failureSummary.expiredCount, record.failureSummary.cancelledCount,
      fmt(record.failureSummary.totalFeesLost)))
  end
  if #record.activeAuctions > 0 then
    print("  Active auctions: " .. #record.activeAuctions)
  end
  local function spanLabel(span)
    if span >= 86400 then return math.floor(span / 86400) .. "d"
    elseif span >= 3600 then return math.floor(span / 3600) .. "h"
    else return math.floor(span / 60) .. "m" end
  end
  if record.history and record.history.points and #record.history.points > 0 then
    local h = record.history
    local span = h.points[#h.points].atTime - h.points[1].atTime
    local parts = { string.format("%d snapshots over %s", #h.points, spanLabel(span)) }
    if h.trend7d then
      parts[#parts + 1] = string.format("7d %s%.1f%%", h.trend7d.deltaPct >= 0 and "+" or "", h.trend7d.deltaPct)
    end
    if h.trend30d then
      parts[#parts + 1] = string.format("30d %s%.1f%%", h.trend30d.deltaPct >= 0 and "+" or "", h.trend30d.deltaPct)
    end
    print("  Price history: " .. table.concat(parts, ", "))
  end
  if record.inventoryHistory and #record.inventoryHistory.points > 0 then
    local ih = record.inventoryHistory
    local span = ih.points[#ih.points].atTime - ih.points[1].atTime
    local parts = { string.format("%d snapshots over %s", #ih.points, spanLabel(span)) }
    local function formatDelta(t)
      if not t then return nil end
      local sign = t.delta >= 0 and "+" or ""
      local label = string.format("%s%d", sign, t.delta)
      -- Surface per-char detail when more than one character contributed.
      local nonZero = {}
      for ck, d in pairs(t.byCharDelta) do
        if d ~= 0 then nonZero[#nonZero + 1] = { ck = ck, d = d } end
      end
      if #nonZero >= 2 then
        table.sort(nonZero, function(a, b) return math.abs(a.d) > math.abs(b.d) end)
        local detail = {}
        for i = 1, math.min(3, #nonZero) do
          detail[i] = string.format("%s %s%d",
            nonZero[i].ck, nonZero[i].d >= 0 and "+" or "", nonZero[i].d)
        end
        label = label .. " (" .. table.concat(detail, ", ") .. ")"
      end
      return label
    end
    local d7  = formatDelta(ih.trend7d)
    local d30 = formatDelta(ih.trend30d)
    if d7  then parts[#parts + 1] = "7d Δ "  .. d7  end
    if d30 then parts[#parts + 1] = "30d Δ " .. d30 end
    print("  Inventory history: " .. table.concat(parts, ", "))
  end
end
