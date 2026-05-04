-- Tally — UI/LedgerPage.lua
--
-- Transaction ledger view. Filter chips at top (All / Sales / Purchases /
-- AH Activity / Other), Reconciled/Raw mode toggle (TLY-30), totals row
-- (income / expense / net / count), and a sortable, column-resizable
-- transaction table powered by Cogworks' CreateScrollTable primitive.
--
-- Reads via ns.Ledger:Reconcile (default) or ns.Ledger:Query (Raw mode).
-- Reconciled mode collapses multi-source captures of the same event into
-- one row — fixes the "Native + Journalator both saw the sale → two
-- rows" duplication that confuses tester triage. Raw mode preserves the
-- per-source view for power-user debugging and Compare-tab follow-up
-- ("which adapter contributed which row?"). Source-agnostic either way —
-- every registered source's entries appear, identified by the `source`
-- column (representative source for reconciled rows, exact source for
-- raw rows).

local addonName, ns = ...
ns.UI = ns.UI or {}

local function getCogworks()
  return LibStub and LibStub("Cogworks-1.0", true) or nil
end

local function themeColor(key, fallback)
  local cw = getCogworks()
  if cw and cw.Theme and cw.Theme[key] then
    local c = cw.Theme[key]
    return c[1], c[2], c[3], c[4]
  end
  fallback = fallback or { 1, 1, 1, 1 }
  return fallback[1], fallback[2], fallback[3], fallback[4]
end

local function formatGoldShort(copper)
  copper = math.floor(math.abs(copper or 0))
  local gold = math.floor(copper / 10000)
  if gold >= 1000000 then return string.format("%.1fM|cffffd700g|r", gold / 1000000)
  elseif gold >= 1000 then return string.format("%.1fk|cffffd700g|r", gold / 1000) end
  return ns.NetWorth.FormatGold(copper)
end

-- Filter chip definitions. Each chip's `kinds` is fed directly into
-- Ledger:Query so counts come from the ledger, not UI-side filtering.
local FILTERS = {
  { label = "All",          kinds = nil },
  { label = "Sales",        kinds = { "sale" } },
  { label = "Purchases",    kinds = { "purchase" } },
  { label = "AH Activity",  kinds = { "ah-cancel", "ah-expire", "ah-fee" } },
  { label = "Other",        kinds = { "vendor-sell", "vendor-buy", "mail-receive",
                                      "mail-send", "trade", "repair", "refund" } },
}

local MAX_ROWS = 500

-- Color escape strings for the kind column. Each entry produces a
-- "|cffRRGGBBkind|r" wrapping at format time. Hex literals are pre-baked
-- once instead of building them on every cell render.
local function buildKindColors()
  local cw = getCogworks()
  local function hex(key, r, g, b)
    if cw and cw.Theme and cw.Theme[key] then
      r, g, b = cw.Theme[key][1], cw.Theme[key][2], cw.Theme[key][3]
    end
    return string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5),
      math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
  end
  return {
    sale          = hex("success", 0.30, 0.85, 0.30),
    purchase      = hex("error",   1.00, 0.40, 0.40),
    ["ah-fee"]    = hex("error",   1.00, 0.40, 0.40),
    ["ah-cancel"] = hex("warning", 1.00, 0.78, 0.10),
    ["ah-expire"] = hex("warning", 1.00, 0.78, 0.10),
  }
end

-- Hand-rolled chip — replace once cogworks#19 (segmented control) ships.
local function makeChip(parent, label, onClick)
  local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
  btn:SetSize(96, 22)
  btn:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  btn:SetBackdropColor(themeColor("bgLight", { 0.12, 0.12, 0.16, 0.8 }))
  btn:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))

  local text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  text:SetPoint("CENTER")
  text:SetText(label)
  text:SetTextColor(themeColor("text", { 0.9, 0.9, 0.92, 1 }))
  btn.text = text

  btn:SetScript("OnEnter", function(self)
    if not self.selected then self:SetBackdropColor(themeColor("rowHover", { 1, 1, 1, 0.08 })) end
  end)
  btn:SetScript("OnLeave", function(self)
    if not self.selected then self:SetBackdropColor(themeColor("bgLight", { 0.12, 0.12, 0.16, 0.8 })) end
  end)
  btn:SetScript("OnClick", onClick)

  function btn:SetSelected(on)
    self.selected = on
    if on then
      self:SetBackdropColor(themeColor("brass", { 0.83, 0.63, 0.09, 0.7 }))
      self.text:SetTextColor(1, 1, 1, 1)
    else
      self:SetBackdropColor(themeColor("bgLight", { 0.12, 0.12, 0.16, 0.8 }))
      self.text:SetTextColor(themeColor("text", { 0.9, 0.9, 0.92, 1 }))
    end
  end

  return btn
end

function ns.UI.CreateLedgerPage(parent)
  local cw = getCogworks()
  if not (cw and cw.CreateScrollTable) then
    -- Cogworks ScrollTable isn't available. Render a stub so the tab still
    -- opens; surface the missing-primitive state to chat for diagnostics.
    local page = CreateFrame("Frame", nil, parent)
    local fs = page:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    fs:SetPoint("CENTER")
    fs:SetText("Ledger requires Cogworks-1.0 with ScrollTable.")
    return page
  end

  local page = CreateFrame("Frame", nil, parent)
  -- TLY-30: ledgerMode persists across sessions so power users who flip
  -- to Raw for debugging don't get bumped back to Reconciled on every
  -- /reload. Default is Reconciled — that's the everyday correct view.
  TallyDB = TallyDB or {}
  TallyDB.ui = TallyDB.ui or {}
  if TallyDB.ui.ledgerMode ~= "raw" and TallyDB.ui.ledgerMode ~= "reconciled" then
    TallyDB.ui.ledgerMode = "reconciled"
  end
  local state = { filterIdx = 1, mode = TallyDB.ui.ledgerMode }
  local kindColors = buildKindColors()

  -- ============================================================================
  -- Top: filter chips + entry count
  -- ============================================================================

  local filterRow = CreateFrame("Frame", nil, page)
  filterRow:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
  filterRow:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 0)
  filterRow:SetHeight(26)

  local chips = {}
  local prev
  for i, f in ipairs(FILTERS) do
    local chip = makeChip(filterRow, f.label, function()
      state.filterIdx = i
      page:Refresh()
    end)
    if prev then
      chip:SetPoint("LEFT", prev, "RIGHT", 4, 0)
    else
      chip:SetPoint("LEFT", filterRow, "LEFT", 0, 0)
    end
    chips[i] = chip
    prev = chip
  end

  local exportBtn = CreateFrame("Button", nil, filterRow, "UIPanelButtonTemplate")
  exportBtn:SetSize(80, 22)
  exportBtn:SetPoint("RIGHT", filterRow, "RIGHT", -4, 0)
  exportBtn:SetText("Export")

  local countText = filterRow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  countText:SetPoint("RIGHT", exportBtn, "LEFT", -8, 0)
  countText:SetJustifyH("RIGHT")

  -- TLY-30: Reconciled (default) collapses multi-source same-event
  -- captures into one row; Raw shows the per-source rows individually
  -- for power-user debugging. Two chips at the right end of the filter
  -- row, anchored left of the entry-count text. The pair is left
  -- visually-distinct from the kind filter chips by the gap that opens
  -- up when filterRow stretches — they're conceptually independent
  -- (mode applies regardless of which kind filter is active).
  local rawChip, reconChip
  local function syncModeChips()
    reconChip:SetSelected(state.mode == "reconciled")
    rawChip:SetSelected(state.mode == "raw")
  end
  reconChip = makeChip(filterRow, "Reconciled", function()
    if state.mode == "reconciled" then return end
    state.mode = "reconciled"
    TallyDB.ui.ledgerMode = "reconciled"
    syncModeChips()
    page:Refresh()
  end)
  reconChip:SetSize(86, 22)
  rawChip = makeChip(filterRow, "Raw", function()
    if state.mode == "raw" then return end
    state.mode = "raw"
    TallyDB.ui.ledgerMode = "raw"
    syncModeChips()
    page:Refresh()
  end)
  rawChip:SetSize(50, 22)
  rawChip:SetPoint("RIGHT", countText, "LEFT", -10, 0)
  reconChip:SetPoint("RIGHT", rawChip, "LEFT", -4, 0)
  syncModeChips()

  -- ============================================================================
  -- Totals row (income / expense / net)
  -- ============================================================================

  local totalsRow = CreateFrame("Frame", nil, page, "BackdropTemplate")
  totalsRow:SetPoint("TOPLEFT", filterRow, "BOTTOMLEFT", 0, -8)
  totalsRow:SetPoint("TOPRIGHT", filterRow, "BOTTOMRIGHT", 0, -8)
  totalsRow:SetHeight(40)
  totalsRow:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  totalsRow:SetBackdropColor(themeColor("bgDark", { 0.04, 0.04, 0.07, 0.6 }))
  totalsRow:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))

  local function makeStat(parent, x, label)
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -4)
    lbl:SetText(label)
    lbl:SetTextColor(themeColor("textDim", { 0.6, 0.6, 0.6, 1 }))
    local val = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    val:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -2)
    val:SetTextColor(themeColor("text", { 0.9, 0.9, 0.92, 1 }))
    return val
  end

  local valIncome  = makeStat(totalsRow, 8,   "INCOME")
  local valExpense = makeStat(totalsRow, 160, "EXPENSE")
  local valNet     = makeStat(totalsRow, 320, "NET")
  local valCount   = makeStat(totalsRow, 480, "ENTRIES")

  -- ============================================================================
  -- Cogworks ScrollTable — sortable, drag-resizable columns
  -- ============================================================================

  -- Column formatters. ScrollTable calls `format(value, rowData)` per cell.
  local function formatKind(v)
    if not v or v == "" then return "" end
    local color = kindColors[v]
    return color and (color .. v .. "|r") or v
  end

  local function formatAmount(v)
    if not v or v == 0 then
      return "|cff999999—|r"
    elseif v > 0 then
      return "|cff4cd64c+" .. formatGoldShort(v) .. "|r"
    else
      return "|cffff6666-" .. formatGoldShort(-v) .. "|r"
    end
  end

  local tableHost = CreateFrame("Frame", nil, page)
  tableHost:SetPoint("TOPLEFT", totalsRow, "BOTTOMLEFT", 0, -10)
  tableHost:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)

  local scrollTable = cw:CreateScrollTable(tableHost, {
    { key = "date",   label = "DATE",      width = 100, sortable = true },
    { key = "char",   label = "CHARACTER", width = 140, sortable = true },
    { key = "kind",   label = "KIND",      width = 80,  sortable = true, format = formatKind },
    { key = "item",   label = "ITEM",      width = 220, sortable = true },
    { key = "source", label = "SRC",       width = 60,  sortable = true },
    { key = "amount", label = "AMOUNT",    width = 110, sortable = true, align = "RIGHT", format = formatAmount },
  })
  -- Default sort: newest first.
  scrollTable:SetSort("date", false)

  -- ============================================================================
  -- Refresh
  -- ============================================================================

  function page:Refresh()
    if not ns.Ledger then return end
    local filter = FILTERS[state.filterIdx]
    for i, c in ipairs(chips) do c:SetSelected(i == state.filterIdx) end

    local query = {}
    if filter.kinds then query.kinds = filter.kinds end

    -- TLY-30: pull rows + compute totals from whichever view the user is
    -- on. Reconciled mode walks reconciled records; Raw uses Query +
    -- Stats so power users can see per-source rows. Stats over reconciled
    -- records is computed inline since Ledger:Stats hits raw Query.
    local entries
    local stats
    if state.mode == "reconciled" then
      entries = ns.Ledger:Reconcile(query)
      stats = { count = #entries, income = 0, expense = 0, net = 0 }
      for _, r in ipairs(entries) do
        local sign = ns.Ledger:KindSign(r.kind)
        local copper = r.copper or 0
        if sign > 0 then stats.income = stats.income + copper
        elseif sign < 0 then stats.expense = stats.expense + copper end
      end
      stats.net = stats.income - stats.expense
    else
      stats = ns.Ledger:Stats(query)
      entries = ns.Ledger:Query(query)
    end

    valIncome:SetText(formatGoldShort(stats.income))
    valIncome:SetTextColor(themeColor("success", { 0.30, 0.85, 0.30, 1 }))
    valExpense:SetText(formatGoldShort(stats.expense))
    valExpense:SetTextColor(themeColor("error", { 1.00, 0.40, 0.40, 1 }))
    valNet:SetText((stats.net >= 0 and "+" or "-") .. formatGoldShort(stats.net))
    if stats.net >= 0 then
      valNet:SetTextColor(themeColor("success", { 0.30, 0.85, 0.30, 1 }))
    else
      valNet:SetTextColor(themeColor("error", { 1.00, 0.40, 0.40, 1 }))
    end
    valCount:SetText(tostring(stats.count))

    local total = #entries
    countText:SetText(string.format("%d %s (showing latest %d)",
      total,
      state.mode == "reconciled" and "records" or "entries",
      math.min(total, MAX_ROWS)))

    -- Storage is append-only and unordered (TLY-21); sort by atTime descending
    -- so we can take the most-recent MAX_ROWS slice. ScrollTable will re-sort
    -- on its own when the user clicks a header, but the row cap itself needs
    -- chronological order.
    table.sort(entries, function(a, b) return (a.atTime or 0) > (b.atTime or 0) end)

    -- Build row data from the most recent MAX_ROWS entries.
    local rows = {}
    local cap = math.min(total, MAX_ROWS)
    for i = 1, cap do
      local e = entries[i]
      local sign = ns.Ledger:KindSign(e.kind)
      local copper = e.copper or 0
      local signedAmount = sign * copper
      local itemLabel = (e.meta and e.meta.name) or (e.itemID and ("item:" .. e.itemID)) or ""
      if e.count and e.count > 1 then itemLabel = itemLabel .. " ×" .. e.count end

      -- TLY-30: source label. In Reconciled mode multi-source clusters
      -- carry a primary source plus a "+N" suffix for the additional
      -- contributors so the user can spot at-a-glance which rows are
      -- merged from multiple adapters. Single-source rows look the same
      -- as before; Raw mode always renders the exact source.
      local sourceLabel = e.source or ""
      if state.mode == "reconciled" and e.sources then
        local n = 0
        for _ in pairs(e.sources) do n = n + 1 end
        if n > 1 then
          sourceLabel = sourceLabel .. "|cff999999+" .. (n - 1) .. "|r"
        end
      end

      rows[#rows + 1] = {
        date         = date("%m/%d %H:%M", e.atTime or 0),
        char         = e.charKey or "",
        kind         = e.kind or "",
        item         = itemLabel,
        source       = sourceLabel,
        amount       = signedAmount,
        -- Sort overrides: ScrollTable picks up `_sort<Key>` in preference to
        -- the displayed value, so date sorts numerically by epoch and amount
        -- sorts by signed copper (not the formatted "+/-1.2k" string).
        _sortDate    = e.atTime or 0,
        _sortAmount  = signedAmount,
        _sortSource  = e.source or "",  -- sort by primary source, ignoring +N suffix
      }
    end
    scrollTable:SetData(rows)
  end

  -- Export the currently-filtered ledger rows to Cogworks's copy-friendly
  -- dialog. All rows in the active filter, not just the on-screen MAX_ROWS
  -- slice — the dialog is for grabbing data into a GitHub issue or external
  -- analysis tool, where the cap is unhelpful. Falls back to chat for
  -- installs without the lib.
  exportBtn:SetScript("OnClick", function()
    if not ns.Ledger then return end
    local filter = FILTERS[state.filterIdx]
    local query = {}
    if filter.kinds then query.kinds = filter.kinds end

    -- Export mirrors the active mode. Reconciled exports collapse
    -- multi-source captures to the canonical record (with "+N" on
    -- the source field so the receiver knows the row was merged);
    -- Raw exports keep per-source rows so the user can attach them
    -- to a GitHub issue when the question is "which adapter saw what."
    local entries
    local stats
    if state.mode == "reconciled" then
      entries = ns.Ledger:Reconcile(query)
      stats = { count = #entries, income = 0, expense = 0, net = 0 }
      for _, r in ipairs(entries) do
        local sign = ns.Ledger:KindSign(r.kind)
        local copper = r.copper or 0
        if sign > 0 then stats.income = stats.income + copper
        elseif sign < 0 then stats.expense = stats.expense + copper end
      end
      stats.net = stats.income - stats.expense
    else
      stats = ns.Ledger:Stats(query)
      entries = ns.Ledger:Query(query)
    end
    table.sort(entries, function(a, b) return (a.atTime or 0) > (b.atTime or 0) end)

    local lines = {}
    local function emit(s) lines[#lines + 1] = s end

    emit(string.format("Tally Ledger: %s (%d %s, %s mode)",
      filter.label, stats.count or 0,
      state.mode == "reconciled" and "records" or "entries",
      state.mode))
    emit(string.format("  income = %s, expense = %s, net = %s%s",
      formatGoldShort(stats.income or 0),
      formatGoldShort(stats.expense or 0),
      (stats.net or 0) >= 0 and "+" or "-",
      formatGoldShort(stats.net or 0)))
    emit("")

    for _, e in ipairs(entries) do
      local sign = ns.Ledger:KindSign(e.kind)
      local copper = e.copper or 0
      local signedAmount = sign * copper
      local amountStr
      if signedAmount == 0 then amountStr = "0c"
      elseif signedAmount > 0 then amountStr = "+" .. formatGoldShort(signedAmount)
      else amountStr = "-" .. formatGoldShort(-signedAmount) end

      local itemLabel = (e.meta and e.meta.name)
        or (e.itemID and ("item:" .. e.itemID))
        or "?"
      if e.count and e.count > 1 then itemLabel = itemLabel .. " x" .. e.count end

      -- Include "+N" / source-set in the source column for reconciled
      -- exports — the export is meant to be readable plain-text outside
      -- WoW, so embed without color codes.
      local sourceLabel = e.source or "?"
      if state.mode == "reconciled" and e.sources then
        local extras = {}
        for s in pairs(e.sources) do
          if s ~= e.source then extras[#extras + 1] = s end
        end
        if #extras > 0 then
          table.sort(extras)
          sourceLabel = sourceLabel .. "+" .. table.concat(extras, "+")
        end
      end

      emit(string.format("%s | %s | %s | %s | %s | %s",
        date("%m/%d %H:%M", e.atTime or 0),
        e.charKey or "?",
        e.kind or "?",
        sourceLabel,
        itemLabel,
        amountStr))
    end

    local text = table.concat(lines, "\n")
    local cw = getCogworks()
    if cw and cw.CreateCopyDialog then
      cw:CreateCopyDialog(text, string.format(
        "Tally Ledger export (%s, %d %s, %s mode) — paste into a GitHub issue or external tool.",
        filter.label, stats.count or 0,
        state.mode == "reconciled" and "records" or "entries",
        state.mode))
    else
      for _, line in ipairs(lines) do print(line) end
    end
  end)

  return page
end
