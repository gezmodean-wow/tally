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

local function normalizeKey(input)
  if type(input) == "number" then
    return tostring(input) .. ";;", input, nil
  end
  if type(input) == "string" then
    -- itemLink shape
    local linkID = input:match("|Hitem:(%d+)")
    if linkID then
      local id = tonumber(linkID)
      return tostring(id) .. ";;", id, input
    end
    -- bare numeric string
    if input:match("^%d+$") then
      local id = tonumber(input)
      return tostring(id) .. ";;", id, nil
    end
    -- already canonical "id;bonus;mods"
    if input:match("^%d+;") then
      local id = tonumber(input:match("^(%d+);"))
      return input, id, nil
    end
  end
  return nil, nil, nil
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

local function buildOwnership(itemKey, itemID)
  local rollup = ns.Inventory:Get() or {}
  local inventory = {}
  local total = 0

  for charKey, char in pairs(rollup.characters or {}) do
    local entry = char.items and char.items[itemKey]
    if entry and entry.count > 0 then
      table.insert(inventory, {
        charKey = charKey,
        quantity = entry.count,
        locations = {},      -- Phase 1 doesn't split bag/bank/etc.; future enhancement
        lastScan = rollup.lastFullScan,
      })
      total = total + entry.count
    end
  end

  if rollup.warband then
    local entry = rollup.warband.items and rollup.warband.items[itemKey]
    if entry and entry.count > 0 then
      table.insert(inventory, {
        charKey = "Warband",
        quantity = entry.count,
        locations = { warbank = entry.count },
        lastScan = rollup.lastFullScan,
      })
      total = total + entry.count
    end
  end

  return inventory, total
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

-- Augment a research record with FlipQueue log data when FlipQueue is present.
-- Read-only; FlipQueue keeps owning the writes.
local function augmentFromFlipQueue(record, itemID, itemName)
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

      local status = entry.auctionStatus or ""
      local sold = (status == "sold" or status == "collected") and entry.soldPrice
      local active = (status == "active")
      local failed = (status == "expired" or status == "cancelled")

      if sold then
        local soldCopper = entry.soldPrice or copperFromPrice(entry.postedPrice or entry.expectedPrice)
        table.insert(record.sales, {
          soldPrice = soldCopper,
          postedPrice = entry.postedPrice or "",
          targetRealm = entry.targetRealm or "Unknown",
          charKey = entry.charKey or "",
          soldAt = entry.soldAt,
          postedAt = entry.postedAt,
          quantity = entry.postedQuantity or 1,
        })
      elseif failed then
        table.insert(record.failures, {
          postedPrice = entry.postedPrice or "",
          targetRealm = entry.targetRealm or "Unknown",
          charKey = entry.charKey or "",
          postedAt = entry.postedAt,
          auctionStatus = entry.auctionStatus,
          saleOutcome = entry.saleOutcome,
          fee = entry.ahFee or 0,
          totalFeesSpent = entry.totalFeesSpent or 0,
          postAttempts = entry.postAttempts or 0,
          postHistory = entry.postHistory,
        })
      elseif active then
        table.insert(record.activeAuctions, {
          postedPrice = entry.postedPrice or "",
          expectedPrice = entry.expectedPrice or "",
          targetRealm = entry.targetRealm or "Unknown",
          charKey = entry.charKey or "",
          postedAt = entry.postedAt,
          quantity = entry.postedQuantity or 1,
        })
      end

      if entry.buyPrice and entry.buyPrice ~= "" then
        table.insert(record.purchases, {
          price = copperFromPrice(entry.buyPrice),
          priceStr = entry.buyPrice,
          realm = entry.buyLocation or entry.targetRealm or "Unknown",
          charKey = entry.charKey or "",
          timestamp = entry.postedAt,
        })
      end
    end
  end

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

  local expired, cancelled, feesLost = 0, 0, 0
  for _, f in ipairs(record.failures) do
    if f.auctionStatus == "expired" then expired = expired + 1
    elseif f.auctionStatus == "cancelled" then cancelled = cancelled + 1 end
    feesLost = feesLost + (f.totalFeesSpent or f.fee or 0)
  end
  record.failureSummary = { expiredCount = expired, cancelledCount = cancelled, totalFeesLost = feesLost }
end

function Research:GetRecord(input, itemName, skipCache)
  local itemKey, itemID, itemLink = normalizeKey(input)
  if not itemKey or not itemID then return nil end

  if not skipCache then
    local cached = cache[itemKey]
    if cached and (time() - cached.ts) < CACHE_TTL then
      return cached.record
    end
  end

  local name, _, quality, _, _, _, _, _, _, icon = GetItemInfo(itemID)
  local record = {
    itemKey = itemKey,
    itemID = itemID,
    itemLink = itemLink,
    name = itemName or name or "",
    icon = icon,
    quality = quality,

    inventory = {},
    totalInventory = 0,

    sales = {},
    salesSummary = { count = 0, totalRevenue = 0, avgPrice = 0, byRealm = {} },
    failures = {},
    failureSummary = { expiredCount = 0, cancelledCount = 0, totalFeesLost = 0 },
    activeAuctions = {},
    fpDeals = {},
    purchases = {},

    pricing = nil,
    valuation = { netWorthContribution = 0 },
    tsm = nil,           -- preserved for FlipQueue compatibility; populated below
    history = nil,       -- Phase 2
    categories = {},     -- Phase 4
  }

  record.inventory, record.totalInventory = buildOwnership(itemKey, itemID)
  record.pricing = buildPricing(itemID, itemKey)
  record.tsm = record.pricing.sources -- alias for FlipQueue back-compat
  record.valuation.netWorthContribution = (record.pricing.unitValue or 0) * record.totalInventory

  augmentFromFlipQueue(record, itemID, record.name ~= "" and record.name or nil)

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
  local linkOrName = record.itemLink or record.name or ("item:" .. record.itemID)
  print(prefix .. " " .. linkOrName)
  print(string.format("  Owned: %d (worth %s @ %s)",
    record.totalInventory, fmt(record.valuation.netWorthContribution), record.pricing.strategy))
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
end
