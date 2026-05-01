-- Tally — Ledger.lua
--
-- Canonical, source-agnostic transaction ledger. Tally writes to its own
-- ledger from day one — sibling addons (FlipQueue, TSM Accounting,
-- Auctionator, etc.) are *sources*, not dependencies. Each source produces
-- entries via a registered adapter; Tally's own Native source hooks WoW
-- events directly. Ledger reads are filtered queries over the pooled
-- entries; cross-source dedupe lives at the entry-id layer.
--
-- Entry shape:
--   {
--     id        = "<source>:<sourceId>",   -- unique per real-world record
--                                           -- as known by the source
--     atTime    = epoch,                   -- when the txn happened
--     kind      = "sale" | "purchase" | "ah-cancel" | "ah-expire"
--                 | "vendor-sell" | "vendor-buy" | "mail-receive"
--                 | "mail-send" | "trade" | "repair" | "ah-fee" | "refund",
--     itemKey   = "12345;bonus;mods",      -- canonical key (or nil for
--                                           -- non-item entries like gold-only)
--     itemID    = 12345,                   -- numeric for fast lookup
--     charKey   = "Hugemane-Stormrage",    -- per-character; "Warband" is
--                                           -- a synthetic charKey for
--                                           -- warband-bank events
--     copper    = 50000,                   -- gross amount in copper
--     count     = 1,                       -- quantity transacted
--     source    = "flipqueue",             -- adapter name
--     sourceId  = "abc123",                -- stable identifier within source
--     meta      = { ... },                 -- source-specific extras
--   }
--
-- Storage:
--   TallyDB.ledger = {
--     entries = { ... sorted ascending by atTime ... },
--     byId    = { ["<source>:<sourceId>"] = true },
--   }
--
-- Cross-source dedupe (same real-world event reported by Native + an adapter)
-- is intentionally *not* automated at insert time. Entries from multiple
-- sources for the same event coexist with distinct ids; future work can add
-- view-time consolidation. For now `source` is surfaced in the UI so users
-- understand provenance.

local addonName, ns = ...

local Ledger = {}
ns.Ledger = Ledger

-- Canonical kind enum exposed for adapters and UI filters.
Ledger.Kinds = {
  Sale         = "sale",
  Purchase     = "purchase",
  AhCancel     = "ah-cancel",
  AhExpire     = "ah-expire",
  AhFee        = "ah-fee",
  VendorSell   = "vendor-sell",
  VendorBuy    = "vendor-buy",
  MailReceive  = "mail-receive",
  MailSend     = "mail-send",
  Trade        = "trade",
  Repair       = "repair",
  Refund       = "refund",
}

-- ============================================================================
-- Storage
-- ============================================================================

local function db()
  TallyDB.ledger = TallyDB.ledger or {}
  TallyDB.ledger.entries = TallyDB.ledger.entries or {}
  TallyDB.ledger.byId    = TallyDB.ledger.byId or {}
  return TallyDB.ledger
end

-- ============================================================================
-- Insert
-- ============================================================================
--
-- Performance note (TLY-21): entries are append-only. We deliberately do NOT
-- maintain a sorted invariant on the storage list — sorting on every insert
-- was O(N log N) per row, which made bulk imports of TSM Accounting CSVs
-- (often tens of thousands of rows) burn seconds at PLAYER_LOGIN. Callers
-- that care about chronological order sort the result of Query(); the
-- ScrollTable UI sorts at render time anyway.

local function isValidEntry(e)
  if type(e) ~= "table" then return false end
  if type(e.id) ~= "string" or e.id == "" then return false end
  if type(e.atTime) ~= "number" or e.atTime <= 0 then return false end
  if type(e.kind) ~= "string" or e.kind == "" then return false end
  if type(e.source) ~= "string" or e.source == "" then return false end
  return true
end

-- Insert a single entry. Returns (true, entry) on insert, (false, reason)
-- on dedupe or invalid input. Caller is responsible for setting entry.id;
-- adapters typically use string.format("%s:%s", source, sourceId).
function Ledger:Insert(entry)
  if not isValidEntry(entry) then return false, "invalid entry" end
  local d = db()
  if d.byId[entry.id] then return false, "duplicate" end
  d.byId[entry.id] = true
  d.entries[#d.entries + 1] = entry
  return true, entry
end

-- Batch insert. Returns (insertedCount, skippedCount).
function Ledger:InsertMany(entries)
  if type(entries) ~= "table" then return 0, 0 end
  local d = db()
  local inserted, skipped = 0, 0
  for _, entry in ipairs(entries) do
    if isValidEntry(entry) and not d.byId[entry.id] then
      d.byId[entry.id] = true
      d.entries[#d.entries + 1] = entry
      inserted = inserted + 1
    else
      skipped = skipped + 1
    end
  end
  return inserted, skipped
end

-- ============================================================================
-- Query
-- ============================================================================

-- filter: optional table with any combination of:
--   kind, kinds (list), itemID, itemKey, charKey, source,
--   atTimeFrom, atTimeTo
-- Returns a list of matching entries (refs into storage; do not mutate).
function Ledger:Query(filter)
  filter = filter or {}
  local kindSet
  if filter.kinds then
    kindSet = {}
    for _, k in ipairs(filter.kinds) do kindSet[k] = true end
  end

  local out = {}
  for _, e in ipairs(db().entries) do
    local ok = true
    if filter.kind and e.kind ~= filter.kind then ok = false end
    if ok and kindSet and not kindSet[e.kind] then ok = false end
    if ok and filter.itemID and e.itemID ~= filter.itemID then ok = false end
    if ok and filter.itemKey and e.itemKey ~= filter.itemKey then ok = false end
    if ok and filter.charKey and e.charKey ~= filter.charKey then ok = false end
    if ok and filter.source and e.source ~= filter.source then ok = false end
    if ok and filter.atTimeFrom and e.atTime < filter.atTimeFrom then ok = false end
    if ok and filter.atTimeTo and e.atTime > filter.atTimeTo then ok = false end
    if ok then out[#out + 1] = e end
  end
  return out
end

-- Aggregate statistics over a filtered set. Convenience for UI.
function Ledger:Stats(filter)
  local rows = self:Query(filter)
  local stats = {
    count = #rows,
    income = 0, expense = 0, net = 0,
    byKind = {},
    bySource = {},
  }
  for _, e in ipairs(rows) do
    local copper = e.copper or 0
    local sign = self:KindSign(e.kind)
    if sign > 0 then stats.income = stats.income + copper
    elseif sign < 0 then stats.expense = stats.expense + copper end
    stats.byKind[e.kind] = (stats.byKind[e.kind] or 0) + 1
    stats.bySource[e.source] = (stats.bySource[e.source] or 0) + 1
  end
  stats.net = stats.income - stats.expense
  return stats
end

-- Returns +1 for income kinds, -1 for expense kinds, 0 for neutral tracking.
function Ledger:KindSign(kind)
  if kind == "sale" or kind == "vendor-sell" or kind == "mail-receive"
     or kind == "refund" then
    return 1
  elseif kind == "purchase" or kind == "vendor-buy" or kind == "mail-send"
         or kind == "repair" or kind == "ah-fee" then
    return -1
  end
  -- ah-cancel, ah-expire, trade, ... are neutral (informational only).
  return 0
end

-- ============================================================================
-- Source registry
-- ============================================================================

local sources = {}     -- name → { name, label, importFn, isAvailableFn }
local sourceOrder = {}

-- Register an adapter. opts:
--   label        — UI display name (default: name)
--   importFn     — function() that pulls from the source and calls
--                  Ledger:InsertMany. Returns (insertedCount, skippedCount).
--   isAvailable  — function() returning true if the source can be imported now
--                  (e.g., the underlying addon is loaded with data). Optional.
function Ledger:RegisterSource(name, opts)
  if type(name) ~= "string" or name == "" then return end
  opts = opts or {}
  if not sources[name] then
    sourceOrder[#sourceOrder + 1] = name
  end
  sources[name] = {
    name = name,
    label = opts.label or name,
    importFn = opts.importFn,
    isAvailableFn = opts.isAvailable,
  }
end

function Ledger:GetSources()
  local out = {}
  for _, n in ipairs(sourceOrder) do out[#out + 1] = sources[n] end
  return out
end

function Ledger:IsSourceAvailable(name)
  local s = sources[name]
  if not s then return false end
  if not s.isAvailableFn then return true end
  local ok, available = pcall(s.isAvailableFn)
  return ok and available or false
end

-- Run a single source's import. Returns (inserted, skipped, err).
function Ledger:ImportFromSource(name)
  local s = sources[name]
  if not s or not s.importFn then return 0, 0, "no such source" end
  if s.isAvailableFn then
    local ok, available = pcall(s.isAvailableFn)
    if not ok or not available then return 0, 0, "source unavailable" end
  end
  local ok, inserted, skipped = pcall(s.importFn)
  if not ok then return 0, 0, tostring(inserted) end
  return inserted or 0, skipped or 0, nil
end

-- Run every registered source's import. Returns a per-source result table.
function Ledger:ImportFromAllSources()
  local results = {}
  for _, name in ipairs(sourceOrder) do
    local inserted, skipped, err = self:ImportFromSource(name)
    results[#results + 1] = {
      source = name,
      inserted = inserted,
      skipped = skipped,
      error = err,
    }
  end
  return results
end

-- ============================================================================
-- Maintenance
-- ============================================================================

-- Wipe all entries. Sources can be re-imported afterward.
function Ledger:Clear()
  TallyDB.ledger = nil
  db() -- re-init defaults
end

-- Drop entries from a specific source. Useful when an adapter changes its
-- id scheme and we need to re-import cleanly.
function Ledger:ClearSource(sourceName)
  local d = db()
  local kept = {}
  for _, e in ipairs(d.entries) do
    if e.source == sourceName then
      d.byId[e.id] = nil
    else
      kept[#kept + 1] = e
    end
  end
  d.entries = kept
end

function Ledger:Count()
  return #db().entries
end
