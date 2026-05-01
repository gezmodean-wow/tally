-- Tally — Research/Lifecycle.lua
--
-- Per-item lifecycle synthesis: walks Tally's ledger and constructs
-- "posting cohorts" (one AH listing's full birth → outcome arc) plus
-- cost-basis attribution (FIFO or weighted-average) for the acquisition
-- side of fungible commodities. Computed at query time; no schema change.
--
-- TLY-26. User goal: drill down into individual items, follow each
-- listing's full lifecycle, and surface insights ("how many tries did it
-- take to sell? how much did failed listings cost in deposits?").
--
-- Cohort = one AH listing.
--   Birth: an `ah-deposit` ledger row (Journalator-sourced; TLY-23).
--   Death: zero-or-more `sale` rows summing to count, OR an `ah-expire`
--          row, OR an `ah-cancel` row.
--   Pairing rule: same charKey, same itemID, count match-or-decrement,
--                 within COHORT_PAIR_WINDOW seconds.
--
-- Sources without ah-deposit rows (no Journalator) produce "synthetic"
-- cohorts — one per sale/expire/cancel row, no deposit info, status set
-- to the row's own kind. The Analyze() output flags this so consumers
-- can prompt users to install Journalator for full lifecycle data.
--
-- Cost basis (acquisition):
--   FIFO: oldest unconsumed purchase units consumed first against sales.
--   Avg:  rolling weighted average across all purchases.
--   Both produce per-sale `costBasis` so cohort `netRealized` is honest.

local addonName, ns = ...

local Lifecycle = {}
ns.Lifecycle = Lifecycle

local COHORT_PAIR_WINDOW = 30 * 86400  -- 30 days

-- ============================================================================
-- Helpers
-- ============================================================================

local function ledgerQuery(filter)
  if not (ns.Ledger and ns.Ledger.Query) then return {} end
  return ns.Ledger:Query(filter)
end

-- All ledger rows for an itemID, sorted ascending by atTime. Cohort
-- pairing relies on ordered traversal.
local function rowsForItem(itemID)
  local rows = ledgerQuery({ itemID = itemID })
  table.sort(rows, function(a, b) return (a.atTime or 0) < (b.atTime or 0) end)
  return rows
end

-- Buckets the ledger rows by kind so cohort matching can scan only what it
-- needs. Each list stays in atTime order (preserved from sort above).
local function bucketByKind(rows)
  local buckets = {
    deposits = {},
    sales = {},
    expires = {},
    cancels = {},
    fees = {},
    purchases = {},
    other = {},
  }
  for _, e in ipairs(rows) do
    if e.kind == "ah-deposit" then
      buckets.deposits[#buckets.deposits + 1] = e
    elseif e.kind == "sale" then
      buckets.sales[#buckets.sales + 1] = e
    elseif e.kind == "ah-expire" then
      buckets.expires[#buckets.expires + 1] = e
    elseif e.kind == "ah-cancel" then
      buckets.cancels[#buckets.cancels + 1] = e
    elseif e.kind == "ah-fee" then
      buckets.fees[#buckets.fees + 1] = e
    elseif e.kind == "purchase" or e.kind == "vendor-buy" then
      buckets.purchases[#buckets.purchases + 1] = e
    else
      buckets.other[#buckets.other + 1] = e
    end
  end
  return buckets
end

-- ============================================================================
-- Cost basis
-- ============================================================================

-- Walk purchases + sales in chronological order, attributing per-sale
-- cost basis under the requested method. Returns:
--   { saleCostBasis = { [sale.id] = totalCopperCost },
--     unitCost      = { [sale.id] = avgUnitCopper } }
--
-- For sales that exhaust available purchase inventory (we sold more than we
-- bought via this ledger), the remainder is recorded as `unknown` cost.
local function computeCostBasis(purchaseRows, saleRows, method)
  method = method or "fifo"
  local out = { saleCostBasis = {}, unitCost = {}, unknownUnits = {} }

  if method == "avg" then
    local totalCost = 0
    local totalCount = 0
    -- Merge-sort iteration over purchases + sales by atTime.
    local pIdx, sIdx = 1, 1
    while pIdx <= #purchaseRows or sIdx <= #saleRows do
      local p = purchaseRows[pIdx]
      local s = saleRows[sIdx]
      local takePurchase
      if p and s then takePurchase = (p.atTime or 0) <= (s.atTime or 0)
      elseif p then takePurchase = true
      else takePurchase = false end

      if takePurchase then
        totalCost = totalCost + (p.copper or 0)
        totalCount = totalCount + (p.count or 1)
        pIdx = pIdx + 1
      else
        local count = s.count or 1
        local avg = totalCount > 0 and (totalCost / totalCount) or 0
        local consumed = math.min(count, totalCount)
        local cost = avg * consumed
        out.saleCostBasis[s.id] = cost
        out.unitCost[s.id] = avg
        if consumed < count then
          out.unknownUnits[s.id] = count - consumed
        end
        totalCost = totalCost - cost
        totalCount = totalCount - consumed
        sIdx = sIdx + 1
      end
    end
    return out
  end

  -- FIFO. Build a queue of (unitCost, remaining) lots from purchases, then
  -- consume in order against sales.
  local lots = {}  -- { { unitCost, remaining } }
  local saleIter = 1
  local function consumeForSale(sale)
    local count = sale.count or 1
    local needed = count
    local cost = 0
    while needed > 0 and #lots > 0 do
      local lot = lots[1]
      local take = math.min(needed, lot.remaining)
      cost = cost + take * lot.unitCost
      lot.remaining = lot.remaining - take
      needed = needed - take
      if lot.remaining <= 0 then table.remove(lots, 1) end
    end
    out.saleCostBasis[sale.id] = cost
    out.unitCost[sale.id] = (count - needed) > 0 and (cost / (count - needed)) or 0
    if needed > 0 then out.unknownUnits[sale.id] = needed end
  end

  -- Time-ordered walk: when a purchase predates the next sale, push it into
  -- lots; otherwise consume the sale.
  local pIdx, sIdx = 1, 1
  while pIdx <= #purchaseRows or sIdx <= #saleRows do
    local p = purchaseRows[pIdx]
    local s = saleRows[sIdx]
    local takePurchase
    if p and s then takePurchase = (p.atTime or 0) <= (s.atTime or 0)
    elseif p then takePurchase = true
    else takePurchase = false end

    if takePurchase then
      local count = p.count or 1
      if count > 0 then
        lots[#lots + 1] = {
          unitCost = (p.copper or 0) / count,
          remaining = count,
        }
      end
      pIdx = pIdx + 1
    else
      consumeForSale(s)
      sIdx = sIdx + 1
    end
  end

  return out
end

-- ============================================================================
-- Cohort matching
-- ============================================================================
--
-- Greedy: for each ah-deposit, walk forward through sales/expires/cancels
-- for the same charKey, count-matched within the pairing window. Once a
-- row is consumed by a cohort it can't be re-paired. AH cuts (`ah-fee`)
-- attributed to a sale by atTime proximity (within 5 minutes) and same
-- charKey/copper-pair fingerprint.

local function withinWindow(a, b)
  return math.abs((a.atTime or 0) - (b.atTime or 0)) <= COHORT_PAIR_WINDOW
end

local function consumeOutcome(deposit, candidates, consumed)
  for i, e in ipairs(candidates) do
    if not consumed[e.id]
       and (e.atTime or 0) >= (deposit.atTime or 0)
       and withinWindow(deposit, e)
       and e.charKey == deposit.charKey then
      consumed[e.id] = true
      return e
    end
  end
  return nil
end

-- Sales pair via count-decrement: a deposit of 200 may resolve via two
-- 100-unit sales. We consume the next-closest unconsumed sale rows up to
-- the deposit count, returning the list.
local function consumeSales(deposit, sales, consumed)
  local taken = {}
  local remaining = deposit.count or 1
  for i, s in ipairs(sales) do
    if remaining <= 0 then break end
    if not consumed[s.id]
       and (s.atTime or 0) >= (deposit.atTime or 0)
       and withinWindow(deposit, s)
       and s.charKey == deposit.charKey then
      taken[#taken + 1] = s
      consumed[s.id] = true
      remaining = remaining - (s.count or 1)
    end
  end
  return taken, remaining
end

-- For a sale row, find the nearest ah-fee row sharing charKey within 5min.
-- Many sources (Native, Journalator) emit the fee as a separate row with no
-- structured back-link to the sale, so we use atTime-proximity matching.
local FEE_PAIR_WINDOW = 5 * 60
local function feeForSale(sale, fees, feeConsumed)
  for i, f in ipairs(fees) do
    if not feeConsumed[f.id]
       and f.charKey == sale.charKey
       and math.abs((f.atTime or 0) - (sale.atTime or 0)) <= FEE_PAIR_WINDOW then
      feeConsumed[f.id] = true
      return f
    end
  end
  return nil
end

local function buildCohort(deposit, sales, expires, cancels, fees,
                           consumed, feeConsumed, costBasisOut)
  local saleMatches, unsoldRemainder = consumeSales(deposit, sales, consumed)
  local expireMatch = #saleMatches == 0 and consumeOutcome(deposit, expires, consumed) or nil
  local cancelMatch = #saleMatches == 0 and not expireMatch
    and consumeOutcome(deposit, cancels, consumed) or nil

  local revenue = 0
  local feesPaid = 0
  local soldCount = 0
  local lastSaleTime = deposit.atTime or 0
  local costBasis = 0
  for _, s in ipairs(saleMatches) do
    revenue = revenue + (s.copper or 0)
    soldCount = soldCount + (s.count or 1)
    lastSaleTime = math.max(lastSaleTime, s.atTime or 0)
    local fee = feeForSale(s, fees, feeConsumed)
    if fee then feesPaid = feesPaid + (fee.copper or 0) end
    if costBasisOut and costBasisOut.saleCostBasis[s.id] then
      costBasis = costBasis + costBasisOut.saleCostBasis[s.id]
    end
  end

  local depositCopper = deposit.copper or 0
  local status, depositForfeit
  if expireMatch then
    status = "expired"
    depositForfeit = depositCopper
  elseif cancelMatch then
    status = "cancelled"
    -- Commodity AH refunds 95% on cancel; legacy items lose full deposit.
    -- We don't know the item type at query time without GetItemInfo, so
    -- we surface gross deposit and let the analysis layer estimate.
    depositForfeit = depositCopper * 0.05
  elseif #saleMatches > 0 and unsoldRemainder <= 0 then
    status = "sold"
    depositForfeit = 0
  elseif #saleMatches > 0 then
    status = "partial"
    depositForfeit = 0
  else
    status = "pending"
    depositForfeit = 0
  end

  local netRealized = revenue - feesPaid - depositForfeit - costBasis

  return {
    synthetic = false,
    postedAt = deposit.atTime,
    charKey = deposit.charKey,
    count = deposit.count or 1,
    buyout = (deposit.meta and deposit.meta.buyout) or nil,
    bid = (deposit.meta and deposit.meta.bid) or nil,
    deposit = depositCopper,
    sales = saleMatches,
    expire = expireMatch,
    cancel = cancelMatch,
    feesPaid = feesPaid,
    revenue = revenue,
    soldCount = soldCount,
    unsoldRemainder = unsoldRemainder,
    costBasis = costBasis,
    depositForfeit = depositForfeit,
    netRealized = netRealized,
    status = status,
    daysActive = (lastSaleTime - (deposit.atTime or 0)) / 86400,
    sourceId = deposit.id,
  }
end

-- Synthetic cohort built from a single sale/expire/cancel row when no
-- ah-deposit data is available. status comes from the row's kind; deposit
-- info is unknown.
local function buildSyntheticCohort(row, fees, feeConsumed, costBasisOut)
  local status
  if row.kind == "sale" then status = "sold"
  elseif row.kind == "ah-expire" then status = "expired"
  elseif row.kind == "ah-cancel" then status = "cancelled"
  else status = "unknown" end

  local feesPaid = 0
  local costBasis = 0
  if row.kind == "sale" then
    local fee = feeForSale(row, fees, feeConsumed)
    if fee then feesPaid = fee.copper or 0 end
    if costBasisOut and costBasisOut.saleCostBasis[row.id] then
      costBasis = costBasisOut.saleCostBasis[row.id]
    end
  end

  return {
    synthetic = true,
    postedAt = row.atTime,
    charKey = row.charKey,
    count = row.count or 1,
    buyout = nil,
    bid = nil,
    deposit = 0,
    sales = row.kind == "sale" and { row } or {},
    expire = row.kind == "ah-expire" and row or nil,
    cancel = row.kind == "ah-cancel" and row or nil,
    feesPaid = feesPaid,
    revenue = row.kind == "sale" and (row.copper or 0) or 0,
    soldCount = row.kind == "sale" and (row.count or 1) or 0,
    unsoldRemainder = 0,
    costBasis = costBasis,
    depositForfeit = 0,
    netRealized = (row.kind == "sale" and (row.copper or 0) or 0) - feesPaid - costBasis,
    status = status,
    daysActive = 0,
    sourceId = row.id,
  }
end

-- ============================================================================
-- Public: GetCohorts
-- ============================================================================
--
-- Returns (cohorts, info) where:
--   cohorts = list ordered by postedAt ascending
--   info    = { hasDeposits = bool, syntheticCount, depositCount,
--               unmatchedSales, costBasisMethod }
function Lifecycle:GetCohorts(itemID, opts)
  opts = opts or {}
  local method = opts.costBasisMethod or "fifo"
  local rows = rowsForItem(itemID)
  if #rows == 0 then return {}, { hasDeposits = false, syntheticCount = 0 } end

  local b = bucketByKind(rows)
  local costBasis = computeCostBasis(b.purchases, b.sales, method)

  local cohorts = {}
  local consumed = {}
  local feeConsumed = {}

  -- Phase 1: real cohorts from ah-deposit rows.
  for _, deposit in ipairs(b.deposits) do
    cohorts[#cohorts + 1] = buildCohort(deposit, b.sales, b.expires, b.cancels,
                                        b.fees, consumed, feeConsumed, costBasis)
  end

  -- Phase 2: synthetic cohorts from any unconsumed sale/expire/cancel rows.
  -- These are AH events we know happened but lack a paired deposit (no
  -- Journalator, or the deposit is from before the user installed Tally).
  local syntheticCount = 0
  local function addSynthetic(list)
    for _, row in ipairs(list) do
      if not consumed[row.id] then
        cohorts[#cohorts + 1] = buildSyntheticCohort(row, b.fees, feeConsumed, costBasis)
        syntheticCount = syntheticCount + 1
      end
    end
  end
  addSynthetic(b.sales)
  addSynthetic(b.expires)
  addSynthetic(b.cancels)

  table.sort(cohorts, function(a, b)
    return (a.postedAt or 0) < (b.postedAt or 0)
  end)

  local info = {
    hasDeposits = #b.deposits > 0,
    depositCount = #b.deposits,
    syntheticCount = syntheticCount,
    unmatchedSales = 0,
    costBasisMethod = method,
  }
  for _, sale in ipairs(b.sales) do
    if not consumed[sale.id] then info.unmatchedSales = info.unmatchedSales + 1 end
  end
  return cohorts, info
end

-- ============================================================================
-- Public: Analyze
-- ============================================================================
--
-- Insight summary over the cohort list. Drives the Lifecycle page's
-- analysis card. All copper amounts are in copper; consumer formats.

function Lifecycle:Analyze(itemID, opts)
  local cohorts, info = self:GetCohorts(itemID, opts)
  local analysis = {
    itemID = itemID,
    cohortCount = #cohorts,
    soldCohorts = 0,
    expiredCohorts = 0,
    cancelledCohorts = 0,
    pendingCohorts = 0,
    partialCohorts = 0,
    totalRevenue = 0,
    totalFeesPaid = 0,
    totalDepositForfeit = 0,
    totalCostBasis = 0,
    netProfit = 0,
    soldUnits = 0,
    avgListPriceCopper = 0,
    bestListPriceCopper = nil,
    worstListPriceCopper = nil,
    avgTimeToSellSec = nil,
    pricingTrend = "flat",  -- "improving" | "declining" | "flat"
    pricingSeries = {},       -- { { atTime, buyout } }
    info = info,
  }
  if #cohorts == 0 then return analysis end

  local saleTimes = {}
  local listPrices = {}
  local soldCount = 0

  for _, c in ipairs(cohorts) do
    if c.status == "sold" then analysis.soldCohorts = analysis.soldCohorts + 1
    elseif c.status == "expired" then analysis.expiredCohorts = analysis.expiredCohorts + 1
    elseif c.status == "cancelled" then analysis.cancelledCohorts = analysis.cancelledCohorts + 1
    elseif c.status == "partial" then analysis.partialCohorts = analysis.partialCohorts + 1
    elseif c.status == "pending" then analysis.pendingCohorts = analysis.pendingCohorts + 1 end

    analysis.totalRevenue = analysis.totalRevenue + (c.revenue or 0)
    analysis.totalFeesPaid = analysis.totalFeesPaid + (c.feesPaid or 0)
    analysis.totalDepositForfeit = analysis.totalDepositForfeit + (c.depositForfeit or 0)
    analysis.totalCostBasis = analysis.totalCostBasis + (c.costBasis or 0)
    analysis.soldUnits = analysis.soldUnits + (c.soldCount or 0)

    if c.buyout and c.buyout > 0 then
      listPrices[#listPrices + 1] = c.buyout
      analysis.pricingSeries[#analysis.pricingSeries + 1] = {
        atTime = c.postedAt, buyout = c.buyout,
      }
      if not analysis.bestListPriceCopper or c.buyout > analysis.bestListPriceCopper then
        analysis.bestListPriceCopper = c.buyout
      end
      if not analysis.worstListPriceCopper or c.buyout < analysis.worstListPriceCopper then
        analysis.worstListPriceCopper = c.buyout
      end
    end

    if c.status == "sold" and c.daysActive and c.daysActive >= 0 then
      saleTimes[#saleTimes + 1] = c.daysActive * 86400
      soldCount = soldCount + 1
    end
  end

  analysis.netProfit = analysis.totalRevenue
                     - analysis.totalFeesPaid
                     - analysis.totalDepositForfeit
                     - analysis.totalCostBasis

  if #listPrices > 0 then
    local sum = 0
    for _, p in ipairs(listPrices) do sum = sum + p end
    analysis.avgListPriceCopper = math.floor(sum / #listPrices)
  end

  if soldCount > 0 then
    local sum = 0
    for _, s in ipairs(saleTimes) do sum = sum + s end
    analysis.avgTimeToSellSec = sum / soldCount
  end

  -- Pricing trend: linear-fit slope over the buyout series, normalized by
  -- the mean. Threshold ±2% per cohort gives a binary improving/flat/declining.
  if #analysis.pricingSeries >= 3 then
    local n = #analysis.pricingSeries
    local sumX, sumY, sumXY, sumX2 = 0, 0, 0, 0
    for i, p in ipairs(analysis.pricingSeries) do
      sumX = sumX + i
      sumY = sumY + p.buyout
      sumXY = sumXY + i * p.buyout
      sumX2 = sumX2 + i * i
    end
    local meanY = sumY / n
    local slope = (n * sumXY - sumX * sumY) / math.max(n * sumX2 - sumX * sumX, 1)
    if meanY > 0 then
      local relSlope = slope / meanY
      if relSlope > 0.02 then analysis.pricingTrend = "improving"
      elseif relSlope < -0.02 then analysis.pricingTrend = "declining"
      else analysis.pricingTrend = "flat" end
    end
  end

  return analysis, cohorts
end

-- Convenience: cohorts + analysis bundled.
function Lifecycle:GetRecord(itemID, opts)
  local analysis, cohorts = self:Analyze(itemID, opts)
  return { analysis = analysis, cohorts = cohorts }
end
