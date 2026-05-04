-- Tally — Sources/TSM.lua
--
-- Backfill ledger entries from TSM's Accounting module. TSM stores its
-- transaction history as CSV strings in TradeSkillMasterDB under keys
-- shaped `r@<realm>@internalData@<csvName>`:
--
--   csvSales      — completed sales (auction + vendor; filter by `source` col)
--   csvBuys       — completed buys  (auction + vendor; filter by `source` col)
--   csvExpired    — expired auctions
--   csvCancelled  — cancelled auctions
--
-- Each CSV starts with a header row. Common columns:
--   itemString, stackSize, quantity, price, otherPlayer, player, time, source
-- - `price` is per-unit copper; total = price * quantity.
-- - `source` distinguishes Auction vs Vendor on sales/buys CSVs; absent on
--   expired/cancelled.
-- - `player` is the character name (no realm); realm is the storage-key suffix.
--
-- TSM doesn't quote CSV fields — item strings, numeric fields, and player
-- names don't contain commas — so a minimal split-on-comma parser suffices.
-- (Pattern lifted from FlipQueue's TrackerTSMReconcile.)

local addonName, ns = ...

local TSMSrc = {}
ns.Sources = ns.Sources or {}
ns.Sources.TSM = TSMSrc

local SOURCE_NAME = "tsm"

-- Named loss counters surfaced by /tally diag (TLY-29). Every early-return
-- in the parse path increments one of these so we can see what's being
-- dropped silently. Reset on Register() so each load measures from zero.
TSMSrc.skipCounters = {
  no_item_or_player_or_time = 0,
  unknown_kind = 0,
}

-- ============================================================================
-- Availability
-- ============================================================================

local function isAvailable()
  return type(_G.TradeSkillMasterDB) == "table"
end

-- ============================================================================
-- CSV helpers
-- ============================================================================

local function indexHeader(header)
  local cols = {}
  local idx = 1
  for col in header:gmatch("([^,]+)") do
    cols[col] = idx
    idx = idx + 1
  end
  return cols
end

local function splitRow(row)
  local fields = {}
  local start = 1
  while true do
    local comma = row:find(",", start, true)
    if not comma then
      fields[#fields + 1] = row:sub(start)
      break
    end
    fields[#fields + 1] = row:sub(start, comma - 1)
    start = comma + 1
  end
  return fields
end

-- Iterate `value` as CSV: yield (header_cols, row_fields) per row.
-- Skips empty rows and the header itself.
local function eachRow(value, callback)
  local headerEnd = value:find("\n", 1, true)
  if not headerEnd then return end
  local header = value:sub(1, headerEnd - 1)
  local cols = indexHeader(header)
  local pos = headerEnd + 1
  local len = #value
  while pos <= len do
    local nlPos = value:find("\n", pos, true) or (len + 1)
    if nlPos > pos then
      local row = value:sub(pos, nlPos - 1)
      if row ~= "" then
        callback(cols, splitRow(row))
      end
    end
    pos = nlPos + 1
  end
end

-- ============================================================================
-- Key/value extraction
-- ============================================================================

-- Extract numeric itemID from a TSM itemString. Pets ("p:123") return nil
-- because Tally currently keys research records on numeric itemID; pet
-- handling is a future refinement.
local function itemIDFromTSM(tsmItem)
  if type(tsmItem) ~= "string" or tsmItem == "" then return nil end
  return tonumber(tsmItem:match("^i:(%d+)"))
end

-- Build a stable per-row hash. TSM CSV rows are append-only and rows have a
-- precise epoch `time`; combined with the realm, player, itemString,
-- quantity, and price this is unique per real-world txn.
local function rowHash(realm, kind, fields, cols)
  local item   = fields[cols.itemString or 0] or ""
  local stack  = fields[cols.stackSize or 0]  or ""
  local qty    = fields[cols.quantity or 0]   or ""
  local price  = fields[cols.price or 0]      or ""
  local player = fields[cols.player or 0]     or ""
  local t      = fields[cols.time or 0]       or "0"
  return string.format("%s|%s|%s|%s|%s|%s|%s|%s",
    realm, kind, player, item, stack, qty, price, t)
end

-- ============================================================================
-- Per-CSV import
-- ============================================================================

-- kindResolver(sourceCol) → ledger kind string OR nil to route the row to
-- Ledger.Kinds.Unknown. For Sales/Buys we use the TSM `source` column to
-- distinguish Auction vs Vendor; anything else (Trade, Mail, future TSM
-- additions) returns nil so the row lands in the Unknown bucket carrying
-- the original `src` string in meta.sourceKind. Expired/Cancelled have no
-- `source` column and resolvers return their fixed kind unconditionally.
local function importCSV(realm, value, csvName, kindResolver)
  local entries = {}
  eachRow(value, function(cols, fields)
    local item   = fields[cols.itemString or 0] or ""
    local qty    = tonumber(fields[cols.quantity or 0]) or 1
    local stack  = tonumber(fields[cols.stackSize or 0])
    local price  = tonumber(fields[cols.price or 0])    -- per-unit copper
    local player = fields[cols.player or 0]
    local other  = fields[cols.otherPlayer or 0]
    local t      = tonumber(fields[cols.time or 0])
    local src    = (cols.source and fields[cols.source]) or nil

    if not (item and player and t and t > 0) then
      TSMSrc.skipCounters.no_item_or_player_or_time =
        TSMSrc.skipCounters.no_item_or_player_or_time + 1
      return
    end

    local copper = (price and qty) and (price * qty) or 0
    local charKey = (player or "") .. "-" .. (realm or "")

    local kind = kindResolver(src)
    if not kind then
      -- TLY-29: route to Unknown instead of silently dropping or — the
      -- previous behavior — falling back to "sale" / "purchase" and
      -- mis-categorizing Trade / Mail rows. Hash incorporates the raw
      -- `src` so two rows with different source-kinds at the same
      -- second don't collide.
      TSMSrc.skipCounters.unknown_kind = TSMSrc.skipCounters.unknown_kind + 1
      local hash = rowHash(realm, "unknown:" .. (src or ""), fields, cols)
      local entry = ns.Ledger:BuildUnknownEntry({
        source     = SOURCE_NAME,
        sourceId   = csvName .. ":" .. hash,
        atTime     = t,
        sourceKind = src and src ~= "" and src or "(empty)",
        charKey    = charKey,
        itemID     = itemIDFromTSM(item),
        copper     = copper,
        count      = qty,
        meta       = {
          itemString = item,
          stackSize = stack,
          otherPlayer = other,
          unitPrice = price,
          csvName = csvName,
        },
      })
      if entry then entries[#entries + 1] = entry end
      return
    end

    local hash = rowHash(realm, kind, fields, cols)

    entries[#entries + 1] = {
      id = SOURCE_NAME .. ":" .. kind .. ":" .. hash,
      atTime = t,
      kind = kind,
      itemKey = nil,
      itemID = itemIDFromTSM(item),
      charKey = charKey,
      copper = copper,
      count = qty,
      source = SOURCE_NAME,
      sourceId = kind .. ":" .. hash,
      meta = {
        itemString = item,
        stackSize = stack,
        otherPlayer = other,
        unitPrice = price,
        tsmSource = src,
        csvName = csvName,
      },
    }
  end)
  return entries
end

local function resolverForCSV(csvName)
  if csvName == "csvSales" then
    return function(src)
      if src == "Auction" then return "sale"
      elseif src == "Vendor" then return "vendor-sell" end
      -- TLY-29: previously fell back to "sale" — that misclassified
      -- TSM "Trade" rows (and any future source enum addition) as
      -- auction sales, inflating sale counts and tilting per-item
      -- pricing history. Returning nil now routes the row to
      -- Ledger.Kinds.Unknown with `src` preserved in meta.sourceKind.
      return nil
    end
  elseif csvName == "csvBuys" then
    return function(src)
      if src == "Auction" then return "purchase"
      elseif src == "Vendor" then return "vendor-buy" end
      return nil
    end
  elseif csvName == "csvExpired" then
    return function() return "ah-expire" end
  elseif csvName == "csvCancelled" then
    return function() return "ah-cancel" end
  end
  return function() return nil end
end

-- ============================================================================
-- Top-level import
-- ============================================================================

local CSV_NAMES = { "csvSales", "csvBuys", "csvExpired", "csvCancelled" }

-- Parse phase only — returns the entries that would be inserted. Used by
-- the chunked driver (Ledger:ImportFromAllSourcesChunked) so the bulk insert
-- can be sliced into framerate-friendly batches. The synchronous importAll
-- below is a thin wrapper that calls this and InsertMany.
local function getEntries()
  if not isAvailable() then return {}, 0 end
  local entries = {}

  for _, csvName in ipairs(CSV_NAMES) do
    local pattern = "^r@(.-)@internalData@" .. csvName .. "$"
    local resolver = resolverForCSV(csvName)
    for key, value in pairs(_G.TradeSkillMasterDB) do
      if type(value) == "string" and value ~= "" then
        local realm = key:match(pattern)
        if realm then
          for _, e in ipairs(importCSV(realm, value, csvName, resolver)) do
            entries[#entries + 1] = e
          end
        end
      end
    end
  end

  return entries, 0
end

local function importAll()
  local entries = getEntries()
  return ns.Ledger:InsertMany(entries)
end

-- ============================================================================
-- Registration
-- ============================================================================

function TSMSrc:Register()
  if not ns.Ledger or not ns.Ledger.RegisterSource then return end
  -- Reset skip counters on each load so /tally diag reports the loss
  -- since the most recent session start, not cumulative across days.
  for k in pairs(self.skipCounters) do self.skipCounters[k] = 0 end
  ns.Ledger:RegisterSource(SOURCE_NAME, {
    label = "TSM Accounting",
    importFn = importAll,
    getEntriesFn = getEntries,
    isAvailable = isAvailable,
  })
end

-- Exposed for testing.
TSMSrc.IsAvailable = isAvailable
TSMSrc.ImportAll = importAll
TSMSrc.GetEntries = getEntries
