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
--
-- Phase-1 kinds (Native + TSM + FlipQueue): sale, purchase, ah-cancel,
-- ah-expire, ah-fee, vendor-sell, vendor-buy, mail-receive, mail-send,
-- trade, repair, refund.
--
-- Phase-2 kinds (TLY-23, sourced primarily from Journalator): ah-deposit
-- (post-time escrow paired with sale/expire/cancel at view time), taxi,
-- trainer, quest-reward, loot, mission, trading-post, crafting-order-placed,
-- crafting-order-fulfilled.
Ledger.Kinds = {
  Sale                    = "sale",
  Purchase                = "purchase",
  AhCancel                = "ah-cancel",
  AhExpire                = "ah-expire",
  AhFee                   = "ah-fee",
  AhDeposit               = "ah-deposit",
  VendorSell              = "vendor-sell",
  VendorBuy               = "vendor-buy",
  MailReceive             = "mail-receive",
  MailSend                = "mail-send",
  Trade                   = "trade",
  Repair                  = "repair",
  Refund                  = "refund",
  Taxi                    = "taxi",
  Trainer                 = "trainer",
  QuestReward             = "quest-reward",
  Loot                    = "loot",
  Mission                 = "mission",
  TradingPost             = "trading-post",
  CraftingOrderPlaced     = "crafting-order-placed",
  CraftingOrderFulfilled  = "crafting-order-fulfilled",
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
--
-- Income (+1):  sale, vendor-sell, mail-receive, refund, quest-reward,
--               loot, mission, crafting-order-fulfilled.
-- Expense (-1): purchase, vendor-buy, mail-send, repair, ah-fee, taxi,
--               trainer, trading-post, crafting-order-placed.
-- Neutral (0):  ah-cancel, ah-expire, ah-deposit, trade.
--   ah-deposit is paired with the eventual sale/expire/cancel at view time
--   (Lifecycle module) — gross deposit + outcome together yield the realized
--   loss/recovery. Counting deposit as a live expense would double-count
--   when the sale completes and TSM/Native attribute the cut.
function Ledger:KindSign(kind)
  if kind == "sale" or kind == "vendor-sell" or kind == "mail-receive"
     or kind == "refund" or kind == "quest-reward" or kind == "loot"
     or kind == "mission" or kind == "crafting-order-fulfilled" then
    return 1
  elseif kind == "purchase" or kind == "vendor-buy" or kind == "mail-send"
         or kind == "repair" or kind == "ah-fee" or kind == "taxi"
         or kind == "trainer" or kind == "trading-post"
         or kind == "crafting-order-placed" then
    return -1
  end
  return 0
end

-- ============================================================================
-- Source registry
-- ============================================================================

local sources = {}     -- name → { name, label, importFn, isAvailableFn }
local sourceOrder = {}

-- Register an adapter. opts:
--   label         — UI display name (default: name)
--   importFn      — function() that pulls from the source and calls
--                   Ledger:InsertMany. Returns (insertedCount, skippedCount).
--                   Legacy synchronous path; called by ImportFromAllSources.
--   getEntriesFn  — function() that returns (entries[], skippedAtParse).
--                   Used by ImportFromAllSourcesChunked so the driver can
--                   batch the insert phase with yields. Adapters that don't
--                   provide this fall back to importFn (synchronous).
--   isAvailable   — function() returning true if the source can be imported
--                   now (e.g., the underlying addon is loaded with data).
--                   Optional.
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
    getEntriesFn = opts.getEntriesFn,
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
  -- User-level opt-out (set by the setup wizard or Settings panel) wins
  -- over runtime detection: even if TSM is loaded, a user who unchecked
  -- it in the wizard expects no rows to flow in.
  if TallyDB and TallyDB.disabledSources and TallyDB.disabledSources[name] then
    return false
  end
  if not s.isAvailableFn then return true end
  local ok, available = pcall(s.isAvailableFn)
  return ok and available or false
end

-- User-level enablement. The runtime availability check (sibling addon
-- loaded?) stays separate; this is the user's preference.
function Ledger:SetSourceEnabled(name, enabled)
  TallyDB.disabledSources = TallyDB.disabledSources or {}
  if enabled then
    TallyDB.disabledSources[name] = nil
  else
    TallyDB.disabledSources[name] = true
  end
end

function Ledger:IsSourceEnabled(name)
  if TallyDB and TallyDB.disabledSources and TallyDB.disabledSources[name] then
    return false
  end
  return true
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
-- Chunked import (TLY-25)
-- ============================================================================
--
-- Yield-aware batch insert. Inserts at most opts.chunkSize entries per tick,
-- waiting opts.delaySec between ticks via C_Timer.After. Callbacks fire after
-- each chunk so the wizard's progress widget can update live. Drives via
-- tail-call chain (no coroutine needed; the addon thread yields naturally
-- between C_Timer.After invocations).
--
-- opts:
--   chunkSize   default 500 — entries inserted per tick. Larger = faster
--               wall-clock import; smaller = friendlier framerate.
--   delaySec    default 0.05 — gap between ticks. 0.05s ≈ 3 frames at 60fps.
--   onProgress  function(insertedSoFar, totalAttempted, skippedSoFar)
--   onDone      function(inserted, skipped)
function Ledger:InsertManyChunked(entries, opts)
  opts = opts or {}
  local chunkSize = opts.chunkSize or 500
  local delaySec = opts.delaySec or 0.05

  if type(entries) ~= "table" or #entries == 0 then
    if opts.onDone then pcall(opts.onDone, 0, 0) end
    return
  end

  local d = db()
  local total = #entries
  local idx = 0
  local inserted = 0
  local skipped = 0

  local function step()
    local stop = math.min(idx + chunkSize, total)
    while idx < stop do
      idx = idx + 1
      local e = entries[idx]
      if isValidEntry(e) and not d.byId[e.id] then
        d.byId[e.id] = true
        d.entries[#d.entries + 1] = e
        inserted = inserted + 1
      else
        skipped = skipped + 1
      end
    end
    if opts.onProgress then pcall(opts.onProgress, inserted, total, skipped) end
    if idx < total and C_Timer and C_Timer.After then
      C_Timer.After(delaySec, step)
    else
      if opts.onDone then pcall(opts.onDone, inserted, skipped) end
    end
  end

  step()
end

-- Multi-source chunked driver. Walks registered sources in order, awaiting
-- each source's parse + chunked insert before starting the next. Designed to
-- be called from the setup wizard's onComplete; surfaces per-source progress
-- to a UI/ProgressBar.lua widget via callbacks.
--
-- Sources that expose getEntriesFn use the chunked-insert path. Sources with
-- only the legacy importFn (Native — event-driven, near-zero rows) run
-- synchronously between chunked sources.
--
-- opts:
--   chunkSize    forwarded to InsertManyChunked
--   delaySec     forwarded to InsertManyChunked
--   sourceDelay  default 0.5 — pause between sources so the input thread
--                doesn't stay starved across an entire import.
--   onSourceStart    function(name, label, parsedCount)
--   onSourceProgress function(name, insertedSoFar, total, skippedSoFar)
--   onSourceDone     function(name, inserted, skipped)
--   onComplete       function(results) — results = list of per-source rows
function Ledger:ImportFromAllSourcesChunked(opts)
  opts = opts or {}
  local sourceDelay = opts.sourceDelay or 0.5

  local results = {}
  local sourceIdx = 0

  local function nextSource()
    sourceIdx = sourceIdx + 1
    if sourceIdx > #sourceOrder then
      if opts.onComplete then pcall(opts.onComplete, results) end
      return
    end

    local name = sourceOrder[sourceIdx]
    local s = sources[name]
    if not s then return nextSource() end
    -- IsSourceAvailable also enforces TallyDB.disabledSources opt-out,
    -- so sources the user unchecked in the wizard land here cleanly.
    if not self:IsSourceAvailable(name) then
      results[#results + 1] = { source = name, inserted = 0, skipped = 0, skippedSource = true }
      if opts.onSourceSkipped then pcall(opts.onSourceSkipped, name, s.label) end
      return nextSource()
    end

    -- Prefer the chunkable getEntriesFn path. Falls back to importFn for
    -- adapters that haven't been migrated (e.g., Native, where the import
    -- is event-driven and produces ~0 rows per call anyway).
    if s.getEntriesFn then
      local ok, entries, parseSkipped = pcall(s.getEntriesFn)
      if not ok then
        results[#results + 1] = { source = name, inserted = 0, skipped = 0, error = tostring(entries) }
        return nextSource()
      end
      entries = entries or {}
      parseSkipped = parseSkipped or 0
      if opts.onSourceStart then pcall(opts.onSourceStart, name, s.label, #entries) end

      self:InsertManyChunked(entries, {
        chunkSize = opts.chunkSize,
        delaySec = opts.delaySec,
        onProgress = function(inserted, total, skipped)
          if opts.onSourceProgress then pcall(opts.onSourceProgress, name, inserted, total, skipped) end
        end,
        onDone = function(inserted, skipped)
          results[#results + 1] = {
            source = name,
            inserted = inserted,
            skipped = skipped + parseSkipped,
          }
          if opts.onSourceDone then pcall(opts.onSourceDone, name, inserted, skipped + parseSkipped) end
          if C_Timer and C_Timer.After then
            C_Timer.After(sourceDelay, nextSource)
          else
            nextSource()
          end
        end,
      })
    else
      -- Legacy path: synchronous. Native lives here (0-N invoice rows from
      -- the open inbox; cheap regardless).
      if opts.onSourceStart then pcall(opts.onSourceStart, name, s.label, nil) end
      local ok, inserted, skipped = pcall(s.importFn or function() return 0, 0 end)
      if not ok then
        results[#results + 1] = { source = name, inserted = 0, skipped = 0, error = tostring(inserted) }
      else
        results[#results + 1] = { source = name, inserted = inserted or 0, skipped = skipped or 0 }
        if opts.onSourceDone then pcall(opts.onSourceDone, name, inserted or 0, skipped or 0) end
      end
      if C_Timer and C_Timer.After then
        C_Timer.After(sourceDelay, nextSource)
      else
        nextSource()
      end
    end
  end

  nextSource()
end

-- ============================================================================
-- Source comparison (TLY-27)
-- ============================================================================
--
-- Aligns rows from two sources into one row-by-row diff view. Match tiers,
-- in fall-through order:
--   strict — same (charKey, itemID, count, copper) within ±60s
--   loose  — same (charKey, itemID, count) within ±5min (ignores copper)
--   name   — same (charKey, lower(itemName)) within ±5min (TLY-37; only
--            considered when A has nil itemID + a non-empty name. Connects
--            historical rows that pre-date itemID resolution at the adapter
--            source against rows that have it populated.)
--   fuzzy  — same (charKey, itemID) within ±1h (ignores count + copper)
--
-- Returns a list of pairs:
--   { a = entryA|nil, b = entryB|nil, tier = "strict"|"loose"|"name"|"fuzzy"|"unique" }
--
-- Rows present in only one source render with the other side nil and
-- tier = "unique". Same source appearing in both A and B (sourceA ==
-- sourceB) is a no-op self-pair — we early-return empty.

local STRICT_WINDOW = 60
local LOOSE_WINDOW = 5 * 60
local FUZZY_WINDOW = 60 * 60

-- Pull a comparable name string off a ledger entry. Adapters write the
-- player-facing item name into either `meta.name` (Native, FlipQueue) or
-- `meta.itemName` (some Journalator paths), so we accept either. Lowercased
-- for case-insensitive matching.
local function nameOf(entry)
  if not entry or type(entry.meta) ~= "table" then return nil end
  local name = entry.meta.name or entry.meta.itemName
  if type(name) ~= "string" or name == "" then return nil end
  return string.lower(name)
end

-- Index a row list for O(1) match lookups. Keyed by (charKey, itemID); each
-- bucket holds the chronologically-ordered rows.
local function indexByCharItem(rows)
  local idx = {}
  for _, e in ipairs(rows) do
    if e.charKey and e.itemID then
      local key = e.charKey .. "|" .. tostring(e.itemID)
      idx[key] = idx[key] or {}
      table.insert(idx[key], e)
    end
  end
  for _, list in pairs(idx) do
    table.sort(list, function(a, b) return (a.atTime or 0) < (b.atTime or 0) end)
  end
  return idx
end

-- Secondary index for the name-tier fallback. Keyed by (charKey, lower(name));
-- only populated for entries with a non-empty meta.name / meta.itemName.
local function indexByCharName(rows)
  local idx = {}
  for _, e in ipairs(rows) do
    local name = nameOf(e)
    if e.charKey and name then
      local key = e.charKey .. "|" .. name
      idx[key] = idx[key] or {}
      table.insert(idx[key], e)
    end
  end
  for _, list in pairs(idx) do
    table.sort(list, function(a, b) return (a.atTime or 0) < (b.atTime or 0) end)
  end
  return idx
end

-- Find a match for entry `a` in `bucket` (B-side rows for the same charKey
-- + itemID). Returns (entry, tier) or nil. Skips entries in `consumed`.
local function findMatch(a, bucket, consumed)
  if not bucket then return nil end
  local aT = a.atTime or 0
  local aCount = a.count or 1
  local aCopper = a.copper or 0

  -- Pass 1: strict.
  for _, b in ipairs(bucket) do
    if not consumed[b]
       and math.abs((b.atTime or 0) - aT) <= STRICT_WINDOW
       and (b.count or 1) == aCount
       and (b.copper or 0) == aCopper then
      return b, "strict"
    end
  end
  -- Pass 2: loose.
  for _, b in ipairs(bucket) do
    if not consumed[b]
       and math.abs((b.atTime or 0) - aT) <= LOOSE_WINDOW
       and (b.count or 1) == aCount then
      return b, "loose"
    end
  end
  -- Pass 3: fuzzy.
  for _, b in ipairs(bucket) do
    if not consumed[b]
       and math.abs((b.atTime or 0) - aT) <= FUZZY_WINDOW then
      return b, "fuzzy"
    end
  end
  return nil
end

-- Name-tier match: chronologically-nearest unconsumed B-row in the same
-- (charKey, name) bucket within LOOSE_WINDOW. Used only when the primary
-- (charKey, itemID) pass returns nil for an A-row that has no itemID.
local function findNameMatch(a, bucket, consumed)
  if not bucket then return nil end
  local aT = a.atTime or 0
  for _, b in ipairs(bucket) do
    if not consumed[b]
       and math.abs((b.atTime or 0) - aT) <= LOOSE_WINDOW then
      return b, "name"
    end
  end
  return nil
end

-- Special pseudo-source meaning "every row in the Tally ledger,
-- regardless of which adapter wrote it." Lets the Compare view answer
-- "is my ledger up to date with this source?" instead of just
-- "do source X and source Y agree." Picked from the dropdown when
-- the user wants to see a source's data alongside their actual ledger.
Ledger.PSEUDO_SOURCE_LEDGER = "__ledger"

function Ledger:Compare(sourceA, sourceB, filter)
  if not sourceA or not sourceB then return {}, {} end
  if sourceA == sourceB then return {}, {} end

  filter = filter or {}

  -- The ledger pseudo-source maps to "no source filter" — Query then
  -- returns every entry from every adapter. Real source names map to
  -- a normal {source = name} filter.
  local function queryFor(name)
    if name == self.PSEUDO_SOURCE_LEDGER then
      return self:Query(filter)
    end
    return self:Query(setmetatable({ source = name }, { __index = filter }))
  end

  local rowsA = queryFor(sourceA)
  local rowsB = queryFor(sourceB)

  local indexB = indexByCharItem(rowsB)
  local indexBByName = indexByCharName(rowsB)
  local consumed = {}
  local pairs_out = {}

  -- Walk A in chronological order.
  table.sort(rowsA, function(a, b) return (a.atTime or 0) < (b.atTime or 0) end)

  for _, a in ipairs(rowsA) do
    local key = (a.charKey or "?") .. "|" .. tostring(a.itemID or 0)
    local bucket = indexB[key]
    local match, tier = findMatch(a, bucket, consumed)
    if not match and not a.itemID then
      local aName = nameOf(a)
      if aName then
        local nameKey = (a.charKey or "?") .. "|" .. aName
        match, tier = findNameMatch(a, indexBByName[nameKey], consumed)
      end
    end
    if match then
      consumed[match] = true
      pairs_out[#pairs_out + 1] = { a = a, b = match, tier = tier }
    else
      pairs_out[#pairs_out + 1] = { a = a, b = nil, tier = "unique" }
    end
  end

  -- B-side leftovers: rows that nothing in A matched.
  for _, b in ipairs(rowsB) do
    if not consumed[b] then
      pairs_out[#pairs_out + 1] = { a = nil, b = b, tier = "unique" }
    end
  end

  -- Summary stats.
  local stats = {
    aCount = #rowsA, bCount = #rowsB,
    strict = 0, loose = 0, name = 0, fuzzy = 0,
    aOnly = 0, bOnly = 0,
    aCopper = 0, bCopper = 0,
    deltaCopper = 0,
  }
  for _, e in ipairs(rowsA) do stats.aCopper = stats.aCopper + (e.copper or 0) end
  for _, e in ipairs(rowsB) do stats.bCopper = stats.bCopper + (e.copper or 0) end
  stats.deltaCopper = stats.aCopper - stats.bCopper
  for _, p in ipairs(pairs_out) do
    if p.tier == "strict" then stats.strict = stats.strict + 1
    elseif p.tier == "loose" then stats.loose = stats.loose + 1
    elseif p.tier == "name" then stats.name = stats.name + 1
    elseif p.tier == "fuzzy" then stats.fuzzy = stats.fuzzy + 1
    elseif p.tier == "unique" then
      if p.a and not p.b then stats.aOnly = stats.aOnly + 1
      elseif p.b and not p.a then stats.bOnly = stats.bOnly + 1 end
    end
  end

  return pairs_out, stats
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

-- ============================================================================
-- Setup gate (TLY-25)
-- ============================================================================
--
-- Returns true once the user has completed the setup wizard (or has been
-- grandfathered as a pre-wizard upgrader). Source adapters and the
-- import drivers respect this gate — until it returns true, no rows
-- flow into the ledger from any source. The wizard's onComplete
-- handler is the only thing that flips it on.
--
-- Why gate every path: testers reported that even after `/tally reset`
-- (which clears the gate), the deferred PLAYER_LOGIN import + the
-- 5-minute ticker + mailbox scans kept silently writing rows. The
-- expected behavior is "nothing imported until I finish the wizard."
function Ledger:IsSetupComplete()
  return TallyDB and TallyDB.setup and TallyDB.setup.completed and true or false
end
