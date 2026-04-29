-- Tally — UI/LedgerPage.lua
--
-- Transaction ledger view. Filter chips at top (All / Sales / Purchases /
-- AH Activity / Other), totals row (income / expense / net / count), and a
-- scrollable list of recent ledger entries with date, character, kind,
-- item, source, and signed amount.
--
-- Reads via ns.Ledger:Query and Ns.Ledger:Stats. Source-agnostic — every
-- registered source's entries appear here, identified by the `source`
-- column.

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

-- Filter chip definitions. `match(entry)` predicates run per-entry when the
-- chip is active; `kind`-only chips set a Ledger:Query filter directly so
-- counts come from Ledger:Stats rather than UI-side filtering.
local FILTERS = {
  { label = "All",          kinds = nil },
  { label = "Sales",        kinds = { "sale" } },
  { label = "Purchases",    kinds = { "purchase" } },
  { label = "AH Activity",  kinds = { "ah-cancel", "ah-expire", "ah-fee" } },
  { label = "Other",        kinds = { "vendor-sell", "vendor-buy", "mail-receive",
                                      "mail-send", "trade", "repair", "refund" } },
}

local MAX_ROWS = 500

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
  local page = CreateFrame("Frame", nil, parent)
  local state = { filterIdx = 1 }

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

  local countText = filterRow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  countText:SetPoint("RIGHT", filterRow, "RIGHT", -4, 0)
  countText:SetJustifyH("RIGHT")

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
  -- Header row + scrollable transaction list
  -- ============================================================================

  local headerRow = CreateFrame("Frame", nil, page)
  headerRow:SetPoint("TOPLEFT", totalsRow, "BOTTOMLEFT", 0, -10)
  headerRow:SetPoint("TOPRIGHT", totalsRow, "BOTTOMRIGHT", 0, -10)
  headerRow:SetHeight(16)

  local function makeHeader(parent, x, w, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetPoint("LEFT", parent, "LEFT", x, 0)
    fs:SetWidth(w)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    fs:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))
    return fs
  end

  -- Column layout (matched in row creation below).
  --   Date     0   100
  --   Char   100   140
  --   Kind   240    80
  --   Item   320   220
  --   Source 540    60
  --   Amount 600   →end (right-justified)
  makeHeader(headerRow, 0,   100, "DATE")
  makeHeader(headerRow, 100, 140, "CHARACTER")
  makeHeader(headerRow, 240, 80,  "KIND")
  makeHeader(headerRow, 320, 220, "ITEM")
  makeHeader(headerRow, 540, 60,  "SRC")
  local amountHdr = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  amountHdr:SetPoint("RIGHT", headerRow, "RIGHT", -4, 0)
  amountHdr:SetText("AMOUNT")
  amountHdr:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local scroll = CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", headerRow, "BOTTOMLEFT", 0, -2)
  scroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -22, 0)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(640, 1)
  scroll:SetScrollChild(content)

  local rowPool = {}

  local function getRow(i)
    local r = rowPool[i]
    if not r then
      r = CreateFrame("Frame", nil, content)
      r:SetHeight(16)
      r:SetPoint("LEFT", content, "LEFT", 0, 0)
      r:SetPoint("RIGHT", content, "RIGHT", 0, 0)

      r.date = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      r.date:SetPoint("LEFT", r, "LEFT", 0, 0)
      r.date:SetWidth(100); r.date:SetJustifyH("LEFT")

      r.char = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      r.char:SetPoint("LEFT", r, "LEFT", 100, 0)
      r.char:SetWidth(140); r.char:SetJustifyH("LEFT")

      r.kind = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      r.kind:SetPoint("LEFT", r, "LEFT", 240, 0)
      r.kind:SetWidth(80); r.kind:SetJustifyH("LEFT")

      r.item = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      r.item:SetPoint("LEFT", r, "LEFT", 320, 0)
      r.item:SetWidth(220); r.item:SetJustifyH("LEFT")

      r.source = r:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      r.source:SetPoint("LEFT", r, "LEFT", 540, 0)
      r.source:SetWidth(60); r.source:SetJustifyH("LEFT")

      r.amount = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      r.amount:SetPoint("RIGHT", r, "RIGHT", -4, 0)
      r.amount:SetJustifyH("RIGHT")

      rowPool[i] = r
    end
    return r
  end

  -- Color hint for kind labels.
  local KIND_COLORS = {
    sale         = function() return themeColor("success", { 0.30, 0.85, 0.30, 1 }) end,
    purchase     = function() return themeColor("error",   { 1.00, 0.40, 0.40, 1 }) end,
    ["ah-fee"]   = function() return themeColor("error",   { 1.00, 0.40, 0.40, 1 }) end,
    ["ah-cancel"]= function() return themeColor("warning", { 1.00, 0.78, 0.10, 1 }) end,
    ["ah-expire"]= function() return themeColor("warning", { 1.00, 0.78, 0.10, 1 }) end,
  }

  -- ============================================================================
  -- Refresh
  -- ============================================================================

  function page:Refresh()
    if not ns.Ledger then return end
    local filter = FILTERS[state.filterIdx]
    for i, c in ipairs(chips) do c:SetSelected(i == state.filterIdx) end

    local query = {}
    if filter.kinds then query.kinds = filter.kinds end

    local stats = ns.Ledger:Stats(query)
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

    -- Newest first; cap to MAX_ROWS for render perf.
    local entries = ns.Ledger:Query(query)
    local total = #entries
    countText:SetText(string.format("%d entries (showing latest %d)",
      total, math.min(total, MAX_ROWS)))

    -- Display from newest backwards.
    local rendered = 0
    for i = #entries, 1, -1 do
      if rendered >= MAX_ROWS then break end
      local e = entries[i]
      local row = getRow(rendered + 1)
      row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -rendered * 16)

      row.date:SetText(date("%m/%d %H:%M", e.atTime or 0))
      row.char:SetText(e.charKey or "")
      row.kind:SetText(e.kind or "")
      local kc = KIND_COLORS[e.kind]
      if kc then row.kind:SetTextColor(kc())
      else row.kind:SetTextColor(themeColor("text", { 0.9, 0.9, 0.92, 1 })) end

      local itemLabel = (e.meta and e.meta.name) or (e.itemID and ("item:" .. e.itemID)) or ""
      if e.count and e.count > 1 then itemLabel = itemLabel .. " ×" .. e.count end
      row.item:SetText(itemLabel)

      row.source:SetText(e.source or "")

      local sign = ns.Ledger:KindSign(e.kind)
      local copper = e.copper or 0
      if sign == 0 or copper == 0 then
        row.amount:SetText("—")
        row.amount:SetTextColor(themeColor("textDim", { 0.6, 0.6, 0.6, 1 }))
      elseif sign > 0 then
        row.amount:SetText("+" .. formatGoldShort(copper))
        row.amount:SetTextColor(themeColor("success", { 0.30, 0.85, 0.30, 1 }))
      else
        row.amount:SetText("-" .. formatGoldShort(copper))
        row.amount:SetTextColor(themeColor("error", { 1.00, 0.40, 0.40, 1 }))
      end

      row:Show()
      rendered = rendered + 1
    end
    for i = rendered + 1, #rowPool do rowPool[i]:Hide() end
    content:SetHeight(math.max(1, rendered * 16))
  end

  return page
end
