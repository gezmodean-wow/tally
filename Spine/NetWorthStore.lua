-- Tally — Spine/NetWorthStore.lua
--
-- Net-worth snapshot store (TLY-81, projection-layer redesign).
--
-- The one time-series Tally must persist itself: net worth over time.
-- Sibling addons own transaction data, but none of them keep a historical
-- net-worth record — so this is Tally's to own (REDESIGN.md §3.2 item 1).
--
-- ── Bounded by time, not row count ──────────────────────────────────────
-- Exactly one snapshot per calendar day, capped by a retention window.
-- At the 180-day default that is ~180 rows, each a fixed handful of
-- scalars plus two small maps (a 4-key pricing breakdown and a per-realm
-- map bounded by realms-traded, not items or transactions). Nothing here
-- grows with trade volume — the structural property the whole redesign
-- exists to guarantee.
--
-- This supersedes the net-worth role of History.lua. History.lua also
-- stored per-item × per-character × per-location inventory snapshots —
-- the row-growing structure REDESIGN.md §3.2 forbids (its own code warned
-- it could pass 1GB of SavedVariables). That module is being retired;
-- per-item price history is tracked separately as TLY-91.
--
-- Storage:
--   TallyDB.networth_snapshots = {
--     config    = { retentionDays = 180, minIntervalSec = 3600 },
--     snapshots = {                  -- append-ordered, ascending atTime
--       {
--         atTime, dayKey, strategy,
--         total, gold, items,        -- net-worth (saleable) basis
--         ownedTotal, ownedItems,    -- owned (incl. bound) basis; gold same
--         breakdown = { tsm, token, vendor, none },
--         byRealm   = { [realmKey] = copper, ["(warband)"] = copper },
--       }, ...
--     },
--   }

local addonName, ns = ...

ns.Spine = ns.Spine or {}

local NetWorthStore = {}
ns.Spine.NetWorthStore = NetWorthStore

local DEFAULT_CONFIG = {
  -- One row per day; 180 rows at the cap.
  retentionDays  = 180,
  -- A snapshot runs two full inventory valuations, and MaybeSnapshot is
  -- driven off the high-frequency InventoryChanged event — so within a
  -- day, only refresh the day's row at most this often.
  minIntervalSec = 60 * 60,
}

local function db()
  TallyDB = TallyDB or {}
  local d = TallyDB.networth_snapshots
  if type(d) ~= "table" then
    d = { config = {}, snapshots = {} }
    TallyDB.networth_snapshots = d
  end
  d.config = d.config or {}
  for k, v in pairs(DEFAULT_CONFIG) do
    if d.config[k] == nil then d.config[k] = v end
  end
  d.snapshots = d.snapshots or {}
  return d
end

-- The calendar-day key a timestamp falls in. Local time deliberately —
-- a player's "day" is their local day; the key only needs to be
-- self-consistent within this module for the one-per-day dedup.
local function dayKey(t)
  return date("%Y-%m-%d", t)
end

-- Realm key for a "Name-Realm" charKey, normalized through Cogworks so it
-- shares the suite realm keyspace (matches UnifiedLedger's realm dimension).
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

-- ── Capture ─────────────────────────────────────────────────────────────

-- Build a snapshot record for `now`. Runs two valuations — net-worth
-- (saleable) and owned (incl. bound) — so the store can serve both views
-- without a re-walk. Returns the record, or nil if net worth could not be
-- computed (no inventory rollup yet).
local function capture(now)
  if not (ns.NetWorth and ns.NetWorth.Snapshot) then return nil end
  local net = ns.NetWorth:Snapshot()
  if not net then return nil end
  local owned = ns.NetWorth:Snapshot({ includeBound = true })

  -- Per-realm net worth, folded from the per-character breakdown. Warband
  -- is realmless; it gets its own pseudo-key.
  local byRealm = {}
  for charKey, c in pairs(net.byCharacter or {}) do
    local rk = realmKeyOf(charKey)
    byRealm[rk] = (byRealm[rk] or 0) + (c.total or 0)
  end
  if net.warband and (net.warband.total or 0) > 0 then
    byRealm["(warband)"] = net.warband.total
  end

  return {
    atTime     = now,
    dayKey     = dayKey(now),
    strategy   = net.strategy,
    total      = net.total or 0,
    gold       = net.gold or 0,
    items      = net.items or 0,
    ownedTotal = (owned and owned.total) or net.total or 0,
    ownedItems = (owned and owned.items) or net.items or 0,
    breakdown  = net.breakdown or { tsm = 0, token = 0, vendor = 0, none = 0 },
    byRealm    = byRealm,
  }
end

-- ── Retention ───────────────────────────────────────────────────────────

-- Drop snapshots past the retention window. One-per-day already bounds
-- the list; this just trims the tail of history.
function NetWorthStore:Prune()
  local d = db()
  local cutoff = time() - (d.config.retentionDays or DEFAULT_CONFIG.retentionDays) * 86400
  local kept = {}
  for _, snap in ipairs(d.snapshots) do
    if (snap.atTime or 0) >= cutoff then kept[#kept + 1] = snap end
  end
  d.snapshots = kept
end

-- ── Snapshot recording ──────────────────────────────────────────────────

-- Record (or refresh) today's snapshot.
--   * No row for today yet → capture and append.
--   * Today's row exists but is older than minIntervalSec → refresh it
--     in place (later in the day = more characters seen = more complete).
--   * Today's row is fresher than minIntervalSec → skip (cheap no-op).
-- opts.force bypasses the interval debounce.
-- Returns (true, record) on capture, or (false, reason) when skipped.
function NetWorthStore:MaybeSnapshot(opts)
  local d = db()
  local now = time()
  local todayKey = dayKey(now)
  local last = d.snapshots[#d.snapshots]
  local haveToday = last and last.dayKey == todayKey

  if not (opts and opts.force) then
    if haveToday and (now - (last.atTime or 0)) < (d.config.minIntervalSec or 0) then
      return false, "min interval not elapsed"
    end
  end

  local rec = capture(now)
  if not rec then return false, "no inventory rollup yet" end

  if haveToday then
    d.snapshots[#d.snapshots] = rec
  else
    d.snapshots[#d.snapshots + 1] = rec
  end
  self:Prune()
  return true, rec
end

-- ── Reads ───────────────────────────────────────────────────────────────

-- Net-worth-over-time series for [startTime, endTime]. Drop-in replacement
-- for the old History:GetNetWorthSeries — same point shape, so UI
-- consumers swap with a one-line API change.
--   opts.includeBound = true → owned basis; false/nil → net (saleable).
-- Returns points ascending by atTime: { atTime, total, gold, items,
-- view, strategy }.
function NetWorthStore:GetSeries(startTime, endTime, opts)
  opts = opts or {}
  local includeBound = opts.includeBound and true or false
  local out = {}
  for _, snap in ipairs(db().snapshots) do
    local at = snap.atTime or 0
    if at >= (startTime or 0) and at <= (endTime or at) then
      out[#out + 1] = {
        atTime   = at,
        total    = includeBound and snap.ownedTotal or snap.total,
        gold     = snap.gold,
        items    = includeBound and snap.ownedItems or snap.items,
        view     = includeBound and "owned" or "net",
        strategy = snap.strategy,
      }
    end
  end
  return out
end

-- The most recent snapshot record, or nil.
function NetWorthStore:GetLatest()
  local s = db().snapshots
  return s[#s]
end

-- The snapshot in effect at a past time: the nearest snapshot at or
-- before atTime, or nil if every snapshot is newer than it. Snapshots
-- are stored append-ordered (ascending atTime), so a forward walk works.
function NetWorthStore:GetAt(atTime)
  if type(atTime) ~= "number" then return nil end
  local found
  for _, snap in ipairs(db().snapshots) do
    if (snap.atTime or 0) <= atTime then found = snap else break end
  end
  return found
end

-- Count / oldest / newest, for diag + Settings.
function NetWorthStore:GetSummary()
  local s = db().snapshots
  return {
    snapshotCount  = #s,
    oldestAt       = s[1] and s[1].atTime or nil,
    lastSnapshotAt = s[#s] and s[#s].atTime or nil,
  }
end

function NetWorthStore:GetConfig()
  return db().config
end

-- Retention horizon in days. Bounds the snapshot list absolutely.
function NetWorthStore:SetRetentionDays(days)
  if type(days) ~= "number" or days <= 0 then
    return false, "retention must be > 0 days"
  end
  db().config.retentionDays = math.floor(days)
  self:Prune()
  return true
end

function NetWorthStore:Clear()
  local d = db()
  d.snapshots = {}
end
