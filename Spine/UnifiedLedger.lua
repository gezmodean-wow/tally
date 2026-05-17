-- Tally — Spine/UnifiedLedger.lua
--
-- The projection API for the data-spine redesign (TLY-80, TLY-90).
--
-- This is the surface views call. It ties the spine together:
--
--   ParseCache  →  Dedup  →  Overrides  →  realm dimension  →  Query
--   (parsed       (cluster   (sparse       (TLY-90)           (filtered
--    sibling       + merge)   manual                           reads for
--    rows)                    corrections)                     the UI)
--
-- The unified ledger is a *computed artifact* — recomputed from the parse
-- cache, never stored. The recompute is memoized in memory and invalidated
-- when the parse cache refreshes, so a view tab open does not re-run the
-- full cluster/merge scan.
--
-- ── Realm dimension (TLY-90) ────────────────────────────────────────────
-- Every unified record carries `realm = { key, side }`:
--   key  — the realm the transaction happened on. Derived from the
--          character's "Name-Realm" charKey (every source already records
--          this). Stamping a more accurate per-source realm — notably
--          FlipQueue's sell-side targetRealm, which differs from the buy
--          realm on a cross-realm flip — is a fast-follow that needs the
--          adapters touched; the charKey realm is correct for the side the
--          transaction's character is on.
--   side — buy / sell / neutral, from the kind. Lets per-realm views
--          classify a realm as buy-dominant vs sell-dominant (a real
--          tester pattern — toeknee buys on 84 realms, sells on 25).
-- `realm.group` (connected-realm rollup, commodity-vs-gear semantics) is
-- intentionally left for later — the spine keeps the finest grain and
-- leaves aggregation to the consumer.

local addonName, ns = ...

ns.Spine = ns.Spine or {}

local UnifiedLedger = {}
ns.Spine.UnifiedLedger = UnifiedLedger

-- Memoized recompute. nil = stale, must rebuild on next read.
local records = nil

-- ── Realm dimension ─────────────────────────────────────────────────────

-- Sell-side / buy-side classification of a transaction kind. Cancels and
-- expires are auction *attempts* with no money moved — neutral here; a
-- per-realm view that wants posting-pressure can read them separately.
local function realmSide(kind)
  if kind == "sale" or kind == "vendor-sell" then return "sell" end
  if kind == "purchase" or kind == "vendor-buy" then return "buy" end
  return "neutral"
end

-- The realm a record's transaction happened on, normalized. Derived from
-- the "Name-Realm" charKey; normalized through Cogworks when available so
-- it shares the suite-wide realm keyspace (EU diacritics etc.).
local function realmKeyOf(charKey)
  if type(charKey) ~= "string" then return "?" end
  local realm = charKey:match("%-(.+)$")
  if not realm or realm == "" then return "?" end
  local cw = LibStub and LibStub("Cogworks-1.0", true)
  if cw and cw.NormalizeRealmKey then
    local ok, normalized = pcall(cw.NormalizeRealmKey, cw, realm)
    if ok and type(normalized) == "string" and normalized ~= "" then
      return normalized
    end
  end
  return (realm:gsub("%s+", "")):lower()
end

-- ── Recompute ───────────────────────────────────────────────────────────

-- Rebuild the unified ledger from the parse cache: dedup/merge, apply
-- manual overrides, stamp the realm dimension. Sorted ascending by atTime
-- so consumers can rely on order. Returns {} when the cache is not ready.
local function rebuild()
  local out = {}
  local PC = ns.Spine.ParseCache
  if not (PC and PC:IsReady() and ns.Spine.Dedup) then
    return out
  end

  local merged = ns.Spine.Dedup.run(PC:GetAllEntries())
  for _, rec in ipairs(merged) do
    -- Overrides:Apply mutates in place and returns the record, or nil
    -- when an "ignore" override drops it.
    if ns.Spine.Overrides then
      rec = ns.Spine.Overrides:Apply(rec)
    end
    if rec then
      rec.realm = {
        key  = realmKeyOf(rec.charKey),
        side = realmSide(rec.kind),
      }
      out[#out + 1] = rec
    end
  end

  table.sort(out, function(a, b) return (a.atTime or 0) < (b.atTime or 0) end)
  return out
end

-- The memoized unified-record list, rebuilt on first read after an
-- Invalidate (or after the parse cache becomes ready).
local function allRecords()
  if records == nil then
    records = rebuild()
  end
  return records
end

-- Drop the memo. Called by ParseCache when it (re)parses; safe to call
-- from anywhere a manual override changes.
function UnifiedLedger:Invalidate()
  records = nil
end

-- ── Reads ───────────────────────────────────────────────────────────────

-- True when the parse cache is ready and Query will return real data.
-- Views check this first and show a spinner while it is false.
function UnifiedLedger:IsReady()
  local PC = ns.Spine.ParseCache
  return PC and PC:IsReady() and true or false
end

-- True if a record passes a filter. Filter keys (all optional):
--   kind        — single kind string
--   kinds       — list of kind strings (record matches any)
--   itemID      — numeric item id
--   itemKey     — canonical item key string
--   charKey     — "Name-Realm"
--   source      — record contributed to by this source
--   realmKey    — normalized realm key
--   realmSide   — "buy" | "sell" | "neutral"
--   atTimeFrom  — inclusive lower bound on atTime
--   atTimeTo    — inclusive upper bound on atTime
--   review      — true to keep only records flagged for review
local function matches(rec, f)
  if f.kind ~= nil and rec.kind ~= f.kind then return false end
  if f.kinds ~= nil then
    local any = false
    for _, k in ipairs(f.kinds) do
      if rec.kind == k then any = true; break end
    end
    if not any then return false end
  end
  if f.itemID ~= nil and rec.itemID ~= f.itemID then return false end
  if f.itemKey ~= nil and rec.itemKey ~= f.itemKey then return false end
  if f.charKey ~= nil and rec.charKey ~= f.charKey then return false end
  if f.source ~= nil and not (rec.sources and rec.sources[f.source]) then
    return false
  end
  if f.realmKey ~= nil and (not rec.realm or rec.realm.key ~= f.realmKey) then
    return false
  end
  if f.realmSide ~= nil and (not rec.realm or rec.realm.side ~= f.realmSide) then
    return false
  end
  if f.atTimeFrom ~= nil and (rec.atTime or 0) < f.atTimeFrom then return false end
  if f.atTimeTo ~= nil and (rec.atTime or 0) > f.atTimeTo then return false end
  if f.review and not rec.review then return false end
  return true
end

-- The unified, deduplicated/merged ledger for a filter — the main read
-- views call. Returns a list (ascending by atTime). Returns {} when the
-- parse cache is not ready; pair with IsReady() to distinguish "no data"
-- from "still parsing".
function UnifiedLedger:Query(filter)
  local all = allRecords()
  if not filter or next(filter) == nil then
    return all
  end
  local out = {}
  for _, rec in ipairs(all) do
    if matches(rec, filter) then
      out[#out + 1] = rec
    end
  end
  return out
end

-- Records flagged for an unresolved source conflict (TLY-80 flag-for-
-- review list). Overrides:Apply has already cleared the flag on any
-- conflict a manual override resolved, so this is the live to-do list.
function UnifiedLedger:GetReviewList()
  return self:Query({ review = true })
end

-- Lightweight aggregates over a filtered slice — count, review count, and
-- a per-realm breakdown (record + by-side counts). Money rollups belong
-- to the Summary view; this is the shape diag and the verification UI
-- need. Pass the same filter shape as Query.
function UnifiedLedger:Stats(filter)
  local rows = self:Query(filter)
  local stats = {
    count   = #rows,
    review  = 0,
    sources = {},
    byRealm = {},
  }
  for _, rec in ipairs(rows) do
    if rec.review then stats.review = stats.review + 1 end
    for src in pairs(rec.sources or {}) do
      stats.sources[src] = (stats.sources[src] or 0) + 1
    end
    local rk = (rec.realm and rec.realm.key) or "?"
    local r = stats.byRealm[rk]
    if not r then
      r = { count = 0, buy = 0, sell = 0, neutral = 0 }
      stats.byRealm[rk] = r
    end
    r.count = r.count + 1
    local side = (rec.realm and rec.realm.side) or "neutral"
    r[side] = (r[side] or 0) + 1
  end
  return stats
end
