-- Tally — History.lua
--
-- Time-series snapshots that capture both:
--   1. Per-itemID prices under the active TSM strategy (strategy-keyed).
--   2. Per-itemID, per-character, per-location inventory counts.
--
-- Snapshots fire on first `InventoryChanged` per session (debounced by
-- the configured min-interval) and on demand via `/tally history snapshot`.
-- Older snapshots roll up to one-per-day past a configurable threshold and
-- are dropped past the retention window. Pricing and inventory share one
-- config block — same cadence, same retention.
--
-- Storage:
--   TallyDB.history = {
--     config = { minIntervalSec, retentionSec, rollupAfterSec },
--     pricing = {
--       [strategy] = {
--         lastSnapshotAt = epoch,
--         snapshots = { { atTime = N, prices = { [itemID] = copper } }, ... },
--       },
--     },
--     inventory = {
--       lastSnapshotAt = epoch,
--       snapshots = {
--         {
--           atTime = N,
--           items = {
--             [itemID] = {
--               [charKey] = { bags=N, reagent=N, bank=N, mail=N,
--                             equipped=N, void=N, auctions=N, warbank=N },
--             },
--           },
--         },
--       },
--     },
--   }
--
-- Vendor and "none" lookups aren't recorded — vendor prices don't change
-- and "none" carries no signal. Inventory entries only record non-zero
-- locations; the "Warband" charKey holds warbank counts.

local addonName, ns = ...

local History = {}
ns.History = History

local DEFAULT_CONFIG = {
  minIntervalSec = 6 * 60 * 60,        -- snapshots no closer than 6h apart
  retentionSec   = 365 * 24 * 60 * 60, -- 1 year max age
  rollupAfterSec = 30 * 24 * 60 * 60,  -- collapse to one-per-day past 30d
}

local LOCATION_KEYS = {
  "bags", "reagent", "bank", "mail",
  "equipped", "void", "auctions", "warbank",
}

local function db()
  -- Migrate v1.0 pricing-only schema if it's still around from earlier dev.
  if TallyDB.pricingHistory and not TallyDB.history then
    TallyDB.history = {
      config = TallyDB.pricingHistory.config,
      pricing = TallyDB.pricingHistory.strategies,
    }
    TallyDB.pricingHistory = nil
  end

  TallyDB.history = TallyDB.history or {}
  TallyDB.history.config = TallyDB.history.config or {}
  for k, v in pairs(DEFAULT_CONFIG) do
    if TallyDB.history.config[k] == nil then
      TallyDB.history.config[k] = v
    end
  end
  TallyDB.history.pricing = TallyDB.history.pricing or {}
  TallyDB.history.inventory = TallyDB.history.inventory or { lastSnapshotAt = 0, snapshots = {} }
  return TallyDB.history
end

local function priceBucket(strategy)
  local d = db()
  d.pricing[strategy] = d.pricing[strategy] or { lastSnapshotAt = 0, snapshots = {} }
  return d.pricing[strategy]
end

local function inventoryBucket()
  return db().inventory
end

-- ============================================================================
-- Config
-- ============================================================================

function History:GetConfig()
  return db().config
end

function History:SetInterval(seconds)
  if type(seconds) ~= "number" or seconds < 0 then
    return false, "interval must be >= 0 seconds (0 disables auto-snapshot)"
  end
  db().config.minIntervalSec = seconds
  return true
end

function History:SetRetention(seconds)
  if type(seconds) ~= "number" or seconds <= 0 then
    return false, "retention must be > 0 seconds"
  end
  db().config.retentionSec = seconds
  return true
end

function History:SetRollupThreshold(seconds)
  if type(seconds) ~= "number" or seconds <= 0 then
    return false, "rollup threshold must be > 0 seconds"
  end
  db().config.rollupAfterSec = seconds
  return true
end

-- ============================================================================
-- Pruning (shared shape)
-- ============================================================================

-- Snapshots arrive append-ordered. Drop anything past retention; for
-- snapshots older than rollupAfterSec, keep only the latest per UTC day.
local function pruneSnapshotList(list, retentionSec, rollupAfterSec)
  if type(list) ~= "table" then return {} end
  local now = time()
  local retentionCutoff = now - retentionSec
  local rollupCutoff    = now - rollupAfterSec

  local kept = {}
  for _, snap in ipairs(list) do
    if snap.atTime >= retentionCutoff then kept[#kept + 1] = snap end
  end
  table.sort(kept, function(a, b) return a.atTime < b.atTime end)

  local result = {}
  local lastDayBucket = nil
  for _, snap in ipairs(kept) do
    if snap.atTime >= rollupCutoff then
      result[#result + 1] = snap
    else
      local day = math.floor(snap.atTime / 86400)
      if lastDayBucket == day then
        result[#result] = snap
      else
        result[#result + 1] = snap
        lastDayBucket = day
      end
    end
  end
  return result
end

function History:Prune()
  local cfg = db().config
  for _, b in pairs(db().pricing) do
    b.snapshots = pruneSnapshotList(b.snapshots, cfg.retentionSec, cfg.rollupAfterSec)
  end
  local inv = inventoryBucket()
  inv.snapshots = pruneSnapshotList(inv.snapshots, cfg.retentionSec, cfg.rollupAfterSec)
end

-- ============================================================================
-- Snapshot recording
-- ============================================================================

local WOW_TOKEN_ITEM_ID = 122270

local function collectOwnedItemIDs()
  local ids = {}
  local rollup = ns.Inventory and ns.Inventory:Get() or nil
  if not rollup then return ids end
  local function fold(items)
    if type(items) ~= "table" then return end
    for _, entry in pairs(items) do
      if entry.itemID and entry.itemID > 0 then
        ids[entry.itemID] = true
      end
    end
  end
  for _, char in pairs(rollup.characters or {}) do
    fold(char.items)
  end
  if rollup.warband then fold(rollup.warband.items) end
  return ids
end

-- Build a per-itemID, per-charKey, per-location count snapshot.
-- Only non-zero locations are emitted, so chars holding nothing of an item
-- don't appear under that item. The synthetic "Warband" charKey carries
-- warbank counts.
local function collectInventorySnapshot()
  local out = {}
  local rollup = ns.Inventory and ns.Inventory:Get() or nil
  if not rollup then return out end

  local function emit(charKey, items)
    if type(items) ~= "table" then return end
    for _, entry in pairs(items) do
      local itemID = entry.itemID
      if itemID and itemID > 0 and entry.locations then
        local hasAny = false
        local locs = {}
        for loc, count in pairs(entry.locations) do
          if count and count > 0 then
            locs[loc] = count
            hasAny = true
          end
        end
        if hasAny then
          out[itemID] = out[itemID] or {}
          out[itemID][charKey] = locs
        end
      end
    end
  end

  for charKey, char in pairs(rollup.characters or {}) do
    emit(charKey, char.items)
  end
  if rollup.warband then
    emit("Warband", rollup.warband.items)
  end
  return out
end

-- Records both pricing and inventory snapshots at the same atTime.
-- Returns (true, info) on success or (false, reason) when skipped.
--   opts.force = true bypasses the min-interval debounce.
function History:Snapshot(opts)
  local strategy = ns.NetWorth and ns.NetWorth:GetStrategy() or nil
  if not strategy or strategy == "" then return false, "no strategy" end

  local cfg = db().config
  local pBucket = priceBucket(strategy)
  local iBucket = inventoryBucket()
  local now = time()

  if not (opts and opts.force) then
    if cfg.minIntervalSec <= 0 then
      return false, "auto-snapshots disabled (interval=0); use /tally history snapshot"
    end
    -- Debounce against whichever bucket fired most recently — pricing and
    -- inventory move in lockstep, so honoring the most recent fire prevents
    -- one of them slipping ahead.
    local lastAt = math.max(pBucket.lastSnapshotAt or 0, iBucket.lastSnapshotAt or 0)
    if (now - lastAt) < cfg.minIntervalSec then
      return false, "min interval not elapsed"
    end
  end

  -- Pricing
  local prices = {}
  local pricedCount = 0
  for itemID in pairs(collectOwnedItemIDs()) do
    local unit, source = ns.Pricing:GetUnitValue(itemID, nil, strategy)
    if unit and unit > 0 and (source == "tsm" or source == "token") then
      prices[itemID] = unit
      pricedCount = pricedCount + 1
    end
  end

  -- Inventory
  local items = collectInventorySnapshot()
  local invItemCount = 0
  for _ in pairs(items) do invItemCount = invItemCount + 1 end

  if pricedCount == 0 and invItemCount == 0 then
    return false, "nothing to record (rollup empty and no priced items)"
  end

  if pricedCount > 0 then
    table.insert(pBucket.snapshots, { atTime = now, prices = prices })
    pBucket.lastSnapshotAt = now
  end
  if invItemCount > 0 then
    table.insert(iBucket.snapshots, { atTime = now, items = items })
    iBucket.lastSnapshotAt = now
  end

  self:Prune()

  return true, {
    strategy = strategy,
    atTime = now,
    pricedItems = pricedCount,
    inventoryItems = invItemCount,
  }
end

function History:MaybeSnapshot()
  return self:Snapshot()
end

-- ============================================================================
-- Pricing queries
-- ============================================================================

function History:GetItemHistory(itemID, strategy)
  if not itemID then return {} end
  strategy = strategy or (ns.NetWorth and ns.NetWorth:GetStrategy())
  if not strategy then return {} end
  local b = db().pricing[strategy]
  if not b or type(b.snapshots) ~= "table" then return {} end
  local out = {}
  for _, snap in ipairs(b.snapshots) do
    local copper = snap.prices and snap.prices[itemID]
    if copper then out[#out + 1] = { atTime = snap.atTime, copper = copper } end
  end
  return out
end

function History:GetItemTrend(itemID, windowSec, strategy)
  local series = self:GetItemHistory(itemID, strategy)
  if #series == 0 then return nil, 0 end
  local cutoff = windowSec and (time() - windowSec) or 0
  local first, latest, n = nil, nil, 0
  for _, point in ipairs(series) do
    if point.atTime >= cutoff then
      first = first or point
      latest = point
      n = n + 1
    end
  end
  if not first or not latest or first.copper == 0 then return nil, n end
  local deltaPct = (latest.copper - first.copper) / first.copper * 100
  return { first = first, latest = latest, deltaPct = deltaPct }, n
end

-- ============================================================================
-- Inventory queries
-- ============================================================================

local function snapshotItemTotal(snap, itemID)
  local rec = snap.items and snap.items[itemID]
  if not rec then return 0, {} end
  local total = 0
  local byChar = {}
  for charKey, locs in pairs(rec) do
    local sub = 0
    for _, n in pairs(locs) do sub = sub + n end
    if sub > 0 then
      byChar[charKey] = sub
      total = total + sub
    end
  end
  return total, byChar
end

-- Returns a list of points: { atTime, total, byChar = { [charKey] = N } }.
-- Per-location detail is preserved in the raw snapshot but not in the trend
-- digest — callers that need it can fetch via GetItemInventoryRaw.
function History:GetItemInventoryHistory(itemID)
  if not itemID then return {} end
  local b = inventoryBucket()
  local out = {}
  for _, snap in ipairs(b.snapshots) do
    local total, byChar = snapshotItemTotal(snap, itemID)
    if total > 0 or next(byChar) then
      out[#out + 1] = { atTime = snap.atTime, total = total, byChar = byChar }
    end
  end
  return out
end

-- Returns the raw per-location detail for itemID at each snapshot —
-- { atTime, byChar = { [charKey] = { [location] = count } } }.
function History:GetItemInventoryRaw(itemID)
  if not itemID then return {} end
  local b = inventoryBucket()
  local out = {}
  for _, snap in ipairs(b.snapshots) do
    local rec = snap.items and snap.items[itemID]
    if rec then
      out[#out + 1] = { atTime = snap.atTime, byChar = rec }
    end
  end
  return out
end

-- Returns ({ first, latest, delta, byCharDelta = { [charKey] = N } }, n).
-- delta is the change in total count over the window. byCharDelta breaks
-- the change down per character; an entry of 0 means unchanged within window.
function History:GetItemInventoryTrend(itemID, windowSec)
  local series = self:GetItemInventoryHistory(itemID)
  if #series == 0 then return nil, 0 end
  local cutoff = windowSec and (time() - windowSec) or 0
  local first, latest, n = nil, nil, 0
  for _, point in ipairs(series) do
    if point.atTime >= cutoff then
      first = first or point
      latest = point
      n = n + 1
    end
  end
  if not first or not latest then return nil, n end
  local byCharDelta = {}
  local seen = {}
  for charKey, count in pairs(first.byChar) do
    seen[charKey] = true
    byCharDelta[charKey] = (latest.byChar[charKey] or 0) - count
  end
  for charKey, count in pairs(latest.byChar) do
    if not seen[charKey] then
      byCharDelta[charKey] = count
    end
  end
  return {
    first = first,
    latest = latest,
    delta = latest.total - first.total,
    byCharDelta = byCharDelta,
  }, n
end

-- ============================================================================
-- Summary + clear
-- ============================================================================

function History:GetSummary()
  local pricing = {}
  for strategy, b in pairs(db().pricing) do
    local oldest = b.snapshots[1] and b.snapshots[1].atTime or nil
    pricing[#pricing + 1] = {
      strategy = strategy,
      snapshotCount = #b.snapshots,
      lastSnapshotAt = b.lastSnapshotAt,
      oldestAt = oldest,
    }
  end
  table.sort(pricing, function(a, b) return a.strategy < b.strategy end)

  local invBucket = inventoryBucket()
  local inventory = {
    snapshotCount = #invBucket.snapshots,
    lastSnapshotAt = invBucket.lastSnapshotAt,
    oldestAt = invBucket.snapshots[1] and invBucket.snapshots[1].atTime or nil,
  }

  return { pricing = pricing, inventory = inventory }
end

-- Clears history. With no argument, wipes both pricing and inventory.
-- With a strategy argument, only the pricing series under that strategy is
-- cleared (inventory is strategy-independent and untouched).
function History:Clear(strategy)
  local d = db()
  if strategy then
    d.pricing[strategy] = nil
  else
    d.pricing = {}
    d.inventory = { lastSnapshotAt = 0, snapshots = {} }
  end
end
