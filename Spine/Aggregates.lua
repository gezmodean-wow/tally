-- Tally — Spine/Aggregates.lua
--
-- Aggregates / summaries store (TLY-82, projection-layer redesign).
--
-- The second thing the spine persists (REDESIGN.md §3.2 item 2): rolled-up
-- summaries keyed by period — per-item P&L, per-realm buy/sell rollups,
-- and operating-cost buckets. These are *derived* from the unified ledger
-- (Spine/UnifiedLedger.lua), which is itself recomputed-on-parse and never
-- stored; the aggregates are persisted so views (Summary's cost-over-time,
-- best/worst products) do not re-fold the whole ledger on every tab open.
--
-- ── Bounded by period × item × realm, never by row count ────────────────
-- Size = periods × distinct-items-traded-that-period × realms-traded.
-- A flipper trades hundreds-to-low-thousands of distinct items per month
-- across tens of realms — bounded. 10k sales of one item is still one
-- `items` entry. A 200k-row account and a 2k-row account produce the same
-- aggregate footprint if they traded the same catalogue. The constant-pool
-- wall cannot recur here.
--
-- Storage:
--   TallyDB.aggregates = {
--     computedAt    = epoch,        -- when this cache was last rebuilt
--     sourceParseAt = epoch,        -- ParseCache finishedAt it was built
--                                   -- from — staleness check
--     periods = {
--       ["2026-04"] = {
--         items  = { [itemID] = { bought, sold, qtyBought, qtySold,
--                                 fees, realized } },
--         realms = { [realmKey] = { buy, sell, qtyBuy, qtySell, side } },
--         costs  = { ahCut, deposits, repairs, other },
--         meta   = { recordCount, partial },
--       }, ...
--     },
--   }
--
-- Recompute replaces `periods` wholesale, so periods that fall out of the
-- shortest sibling source's window simply stop being emitted — no stale
-- accumulation, no separate prune. A hard MAX_PERIODS cap is a belt-and-
-- suspenders bound.

local addonName, ns = ...

ns.Spine = ns.Spine or {}

local Aggregates = {}
ns.Spine.Aggregates = Aggregates

-- Hard cap on retained periods (months). Aggregates are recomputed from
-- the unified ledger, which only ever sees data within the shortest
-- sibling source's retention — so this rarely bites; it just guarantees
-- the store cannot balloon if a source ever reports absurd history depth.
local MAX_PERIODS = 36

-- Kind classification. Sell/buy kinds drive per-item P&L and the per-realm
-- rollup; cost kinds drive the operating-cost buckets.
local SELL_KINDS = { sale = true, ["vendor-sell"] = true }
local BUY_KINDS  = { purchase = true, ["vendor-buy"] = true }
local COST_BUCKET = {
  ["ah-fee"]     = "ahCut",
  ["ah-deposit"] = "deposits",
  repair         = "repairs",
}

local function db()
  TallyDB = TallyDB or {}
  local d = TallyDB.aggregates
  if type(d) ~= "table" then
    d = { periods = {} }
    TallyDB.aggregates = d
  end
  d.periods = d.periods or {}
  return d
end

-- The ParseCache parse this cache should be keyed to, for staleness
-- checks. nil when the cache has never finished a parse.
local function parseStamp()
  local PC = ns.Spine.ParseCache
  if not (PC and PC.GetState) then return nil end
  local st = PC:GetState()
  return st and st.finishedAt or nil
end

-- ── Folding ─────────────────────────────────────────────────────────────

local function newPeriod()
  return {
    items  = {},
    realms = {},
    costs  = { ahCut = 0, deposits = 0, repairs = 0, other = 0 },
    meta   = { recordCount = 0 },
  }
end

local function itemEntry(period, itemID)
  local it = period.items[itemID]
  if not it then
    it = { bought = 0, sold = 0, qtyBought = 0, qtySold = 0, fees = 0, realized = 0 }
    period.items[itemID] = it
  end
  return it
end

-- Fold one unified-ledger record into its period bucket.
local function fold(period, rec)
  period.meta.recordCount = period.meta.recordCount + 1

  local kind   = rec.kind
  local copper = rec.copper or 0
  local count  = rec.count or 0
  local itemID = rec.itemID

  -- Per-item P&L.
  if itemID then
    if SELL_KINDS[kind] then
      local it = itemEntry(period, itemID)
      it.sold = it.sold + copper
      it.qtySold = it.qtySold + count
      it.realized = it.sold - it.bought
    elseif BUY_KINDS[kind] then
      local it = itemEntry(period, itemID)
      it.bought = it.bought + copper
      it.qtyBought = it.qtyBought + count
      it.realized = it.sold - it.bought
    elseif COST_BUCKET[kind] then
      itemEntry(period, itemID).fees = itemEntry(period, itemID).fees + copper
    end
  end

  -- Per-realm buy/sell rollup — only buy/sell kinds carry realm activity.
  if SELL_KINDS[kind] or BUY_KINDS[kind] then
    local rk = (rec.realm and rec.realm.key) or "?"
    local r = period.realms[rk]
    if not r then
      r = { buy = 0, sell = 0, qtyBuy = 0, qtySell = 0 }
      period.realms[rk] = r
    end
    if SELL_KINDS[kind] then
      r.sell = r.sell + copper
      r.qtySell = r.qtySell + count
    else
      r.buy = r.buy + copper
      r.qtyBuy = r.qtyBuy + count
    end
  end

  -- Operating-cost buckets.
  local bucket = COST_BUCKET[kind]
  if bucket then
    period.costs[bucket] = (period.costs[bucket] or 0) + copper
  end
end

-- Classify a realm as buy- / sell-dominant once its period is fully
-- folded. The 1.25× margin keeps near-even realms honestly "mixed".
local function classifyRealm(r)
  if r.buy > r.sell * 1.25 then return "buy" end
  if r.sell > r.buy * 1.25 then return "sell" end
  return "mixed"
end

-- ── Recompute ───────────────────────────────────────────────────────────

-- Rebuild the whole aggregate store from the unified ledger. Called after
-- each parse (hooked into ParseCache.finish) — so at most once per session,
-- the cost amortised into the parse the player already accepted.
--
-- No-ops without clobbering the prior store when the parse cache is not
-- ready (e.g. the spine is disabled) — stale aggregates beat empty ones.
-- Returns true if a recompute ran.
function Aggregates:Recompute()
  local UL = ns.Spine.UnifiedLedger
  if not (UL and UL.IsReady and UL:IsReady()) then
    return false
  end

  local periods = {}
  for _, rec in ipairs(UL:Query({})) do
    local pk = date("%Y-%m", rec.atTime or 0)
    local period = periods[pk]
    if not period then
      period = newPeriod()
      periods[pk] = period
    end
    fold(period, rec)
  end

  -- Finalize: classify realms; flag the current (still-changing) month.
  local currentMonth = date("%Y-%m", time())
  for pk, period in pairs(periods) do
    for _, r in pairs(period.realms) do
      r.side = classifyRealm(r)
    end
    if pk == currentMonth then
      period.meta.partial = true
    end
  end

  -- MAX_PERIODS cap — drop oldest if somehow over.
  local keys = {}
  for pk in pairs(periods) do keys[#keys + 1] = pk end
  if #keys > MAX_PERIODS then
    table.sort(keys)  -- "YYYY-MM" sorts chronologically
    for i = 1, #keys - MAX_PERIODS do
      periods[keys[i]] = nil
    end
  end

  local d = db()
  d.periods = periods
  d.computedAt = time()
  d.sourceParseAt = parseStamp()
  return true
end

-- Recompute only if the store is stale relative to the current parse.
-- The lazy fallback for callers reading aggregates when the eager
-- ParseCache.finish hook did not run (spine was disabled last login, etc.).
function Aggregates:EnsureFresh()
  local d = db()
  if d.sourceParseAt ~= parseStamp() or not d.computedAt then
    return self:Recompute()
  end
  return false
end

-- ── Reads ───────────────────────────────────────────────────────────────

-- The aggregate bucket for a period key ("YYYY-MM"), or nil. Ensures the
-- store is fresh first.
function Aggregates:Get(periodKey)
  self:EnsureFresh()
  return db().periods[periodKey]
end

-- Sorted (chronological) list of period keys present in the store.
function Aggregates:GetPeriods()
  self:EnsureFresh()
  local keys = {}
  for pk in pairs(db().periods) do keys[#keys + 1] = pk end
  table.sort(keys)
  return keys
end

-- Compact summary for /tally diag — period count, total records folded,
-- and the freshness stamps.
function Aggregates:Summary()
  local d = db()
  local periodCount, recordCount = 0, 0
  for _, period in pairs(d.periods) do
    periodCount = periodCount + 1
    recordCount = recordCount + ((period.meta and period.meta.recordCount) or 0)
  end
  return {
    periods       = periodCount,
    records       = recordCount,
    computedAt    = d.computedAt,
    sourceParseAt = d.sourceParseAt,
    stale         = d.sourceParseAt ~= parseStamp(),
  }
end
