-- Tally — UI/NetWorthPage.lua
--
-- Net-worth-over-time page. Time-range button row (7d / 30d / 90d / All),
-- a line chart of saleable net worth across the selected window, and a
-- stats footer showing current total, Δ over window, and snapshot count.

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

local RANGES = {
  { label = "7d",  seconds = 7  * 86400 },
  { label = "30d", seconds = 30 * 86400 },
  { label = "90d", seconds = 90 * 86400 },
  { label = "All", seconds = nil },
}

local function formatGoldShort(copper)
  copper = math.floor(copper or 0)
  local gold = math.floor(copper / 10000)
  if gold >= 1000000 then
    return string.format("%.1fM|cffffd700g|r", gold / 1000000)
  elseif gold >= 1000 then
    return string.format("%.1fk|cffffd700g|r", gold / 1000)
  end
  return ns.NetWorth.FormatGold(copper)
end

local function makeRangeButton(parent, label, onClick)
  local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
  btn:SetSize(48, 22)
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

  btn:SetScript("OnClick", onClick)
  btn:SetScript("OnEnter", function(self)
    self:SetBackdropColor(themeColor("rowHover", { 1, 1, 1, 0.08 }))
  end)
  btn:SetScript("OnLeave", function(self)
    if self.selected then
      self:SetBackdropColor(themeColor("brass", { 0.83, 0.63, 0.09, 0.6 }))
    else
      self:SetBackdropColor(themeColor("bgLight", { 0.12, 0.12, 0.16, 0.8 }))
    end
  end)

  function btn:SetSelected(on)
    self.selected = on
    if on then
      self:SetBackdropColor(themeColor("brass", { 0.83, 0.63, 0.09, 0.6 }))
      self.text:SetTextColor(1, 1, 1, 1)
    else
      self:SetBackdropColor(themeColor("bgLight", { 0.12, 0.12, 0.16, 0.8 }))
      self.text:SetTextColor(themeColor("text", { 0.9, 0.9, 0.92, 1 }))
    end
  end

  return btn
end

local VIEWS = {
  { label = "Saleable", includeBound = false },
  { label = "Owned",    includeBound = true  },
}

function ns.UI.CreateNetWorthPage(parent)
  local page = CreateFrame("Frame", nil, parent)
  local state = { rangeIdx = 2, viewIdx = 1 } -- default: 30d, saleable

  -- Top control row.
  local controlRow = CreateFrame("Frame", nil, page)
  controlRow:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
  controlRow:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 0)
  controlRow:SetHeight(26)

  local rangeButtons = {}
  local prev
  for i, r in ipairs(RANGES) do
    local btn = makeRangeButton(controlRow, r.label, function()
      state.rangeIdx = i
      page:Refresh()
    end)
    if prev then
      btn:SetPoint("LEFT", prev, "RIGHT", 4, 0)
    else
      btn:SetPoint("LEFT", controlRow, "LEFT", 0, 0)
    end
    rangeButtons[i] = btn
    prev = btn
  end

  -- View toggle (Saleable / Owned). Sits to the right of the time range.
  local viewButtons = {}
  local viewPrev
  for i, v in ipairs(VIEWS) do
    local btn = makeRangeButton(controlRow, v.label, function()
      state.viewIdx = i
      page:Refresh()
    end)
    btn:SetWidth(72)
    if viewPrev then
      btn:SetPoint("LEFT", viewPrev, "RIGHT", 4, 0)
    else
      btn:SetPoint("LEFT", prev, "RIGHT", 24, 0)
    end
    viewButtons[i] = btn
    viewPrev = btn
  end

  local strategyText = controlRow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  strategyText:SetPoint("RIGHT", controlRow, "RIGHT", -2, 0)
  strategyText:SetJustifyH("RIGHT")

  -- Chart + per-character table sit side by side. Chart on the left,
  -- table on the right. Chart is anchored both sides — its right edge
  -- is set as a fraction of the middle frame's width on resize so the
  -- char panel always gets a readable share even when the player widens
  -- the main frame. Tester feedback: 440px-fixed chart + remainder for
  -- chars left the chars cramped (long "Char-Realm" names truncated).
  local middle = CreateFrame("Frame", nil, page)
  middle:SetPoint("TOPLEFT", controlRow, "BOTTOMLEFT", 0, -8)
  middle:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 60)

  local CHAR_PANEL_MIN_W = 320  -- enough for "Hugemane-Argent Dawn" + value

  local chart = ns.UI.CreateLineChart(middle, {
    yLabelWidth = 72,
    xLabelHeight = 16,
    yTicks = 4,
    xTicks = 5,
  })
  chart:SetPoint("TOPLEFT", middle, "TOPLEFT", 0, 0)
  chart:SetPoint("BOTTOMLEFT", middle, "BOTTOMLEFT", 0, 0)

  -- Recompute chart width from middle's actual width on every layout.
  -- Char panel claims max(CHAR_PANEL_MIN_W, 35% of width); chart gets the
  -- rest minus a 12px gutter. Falls back to a sensible default before
  -- middle has a measured width.
  local function applyChartWidth()
    local mw = middle:GetWidth()
    if not mw or mw < 1 then return end
    local panelW = math.max(CHAR_PANEL_MIN_W, math.floor(mw * 0.35))
    local chartW = math.max(280, mw - panelW - 12)
    chart:SetWidth(chartW)
  end
  middle:SetScript("OnSizeChanged", function() applyChartWidth() end)
  applyChartWidth()

  chart:SetYFormatter(function(copper)
    return formatGoldShort(copper)
  end)
  chart:SetXFormatter(function(epoch)
    return date("%m/%d", epoch)
  end)

  -- Per-character table (right column).
  local charPanel = CreateFrame("Frame", nil, middle, "BackdropTemplate")
  charPanel:SetPoint("TOPLEFT", chart, "TOPRIGHT", 12, 0)
  charPanel:SetPoint("BOTTOMRIGHT", middle, "BOTTOMRIGHT", 0, 0)
  charPanel:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  charPanel:SetBackdropColor(themeColor("bgDark", { 0.04, 0.04, 0.07, 0.6 }))
  charPanel:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))

  local charHdr = charPanel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  charHdr:SetPoint("TOPLEFT", charPanel, "TOPLEFT", 8, -6)
  charHdr:SetText("PER CHARACTER")
  charHdr:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local charScroll = CreateFrame("ScrollFrame", nil, charPanel, "UIPanelScrollFrameTemplate")
  charScroll:SetPoint("TOPLEFT", charHdr, "BOTTOMLEFT", 0, -4)
  charScroll:SetPoint("BOTTOMRIGHT", charPanel, "BOTTOMRIGHT", -22, 6)
  local charContent = CreateFrame("Frame", nil, charScroll)
  charContent:SetSize(220, 1)
  charScroll:SetScrollChild(charContent)
  -- Track the scroll-frame width so rows fill the available space rather
  -- than the hardcoded 220px stub. Without this, the right-aligned
  -- "value" column hugs the 220px boundary even on a 320px-wide panel.
  charScroll:SetScript("OnSizeChanged", function(self, w, _)
    if w and w > 0 then charContent:SetWidth(w) end
  end)

  local charRows = {}
  local function getCharRow(i)
    local row = charRows[i]
    if not row then
      -- Use a Button so the whole row is clickable. Clicking a row drills
      -- into the Inventory tab filtered to that character — the user's
      -- "I have one char with most of my net worth, why?" question.
      row = CreateFrame("Button", nil, charContent)
      row:SetHeight(34)
      row:SetPoint("LEFT", charContent, "LEFT", 6, 0)
      row:SetPoint("RIGHT", charContent, "RIGHT", -6, 0)

      row.bg = row:CreateTexture(nil, "BACKGROUND")
      row.bg:SetAllPoints()
      row.bg:SetColorTexture(1, 1, 1, 0)

      -- Top line. Name takes everything not claimed by the right-aligned
      -- value — anchoring TOPLEFT/TOPRIGHT with explicit gap lets the
      -- name column scale with the panel width. Cuts off via word-wrap
      -- if the panel is squeezed below CHAR_PANEL_MIN_W (shouldn't
      -- happen with the proportional chart split, but defensive).
      row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      row.name:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
      row.name:SetJustifyH("LEFT")
      row.name:SetWordWrap(false)

      row.value = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
      row.value:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, -2)
      row.value:SetJustifyH("RIGHT")

      -- Constrain name's right edge so it doesn't overrun the value.
      row.name:SetPoint("RIGHT", row.value, "LEFT", -8, 0)

      -- Sub-line: gold vs items + share of total. Answers "why is this
      -- char dominant" at-a-glance; full answer lives in the Inventory
      -- drill-down (click row).
      row.sub = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      row.sub:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -3)
      row.sub:SetPoint("RIGHT", row, "RIGHT", 0, 0)
      row.sub:SetJustifyH("LEFT")
      row.sub:SetWordWrap(false)

      row:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(1, 1, 1, 0.06)
      end)
      row:SetScript("OnLeave", function(self)
        self.bg:SetColorTexture(1, 1, 1, 0)
      end)
      row:SetScript("OnClick", function(self)
        if self._charKey and ns.UI.ShowInventory then
          ns.UI.ShowInventory(self._charKey)
        end
      end)

      charRows[i] = row
    end
    return row
  end

  -- Stats footer.
  local footer = CreateFrame("Frame", nil, page)
  footer:SetPoint("TOPLEFT", middle, "BOTTOMLEFT", 0, -8)
  footer:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)

  local function makeStatLabel(parent, anchorRel, anchorOffset)
    local label = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    label:SetPoint("TOPLEFT", parent, "TOPLEFT", anchorOffset, -4)
    label:SetTextColor(themeColor("textDim", { 0.6, 0.6, 0.6, 1 }))
    local value = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    value:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -2)
    value:SetTextColor(themeColor("text", { 0.9, 0.9, 0.92, 1 }))
    return label, value
  end

  local lblCurrent, valCurrent = makeStatLabel(footer, nil, 0)
  lblCurrent:SetText("CURRENT")
  local lblDelta, valDelta = makeStatLabel(footer, nil, 180)
  lblDelta:SetText("Δ OVER WINDOW")
  local lblSnaps, valSnaps = makeStatLabel(footer, nil, 360)
  lblSnaps:SetText("SNAPSHOTS")

  -- Refresh logic ------------------------------------------------------------

  function page:Refresh()
    if not (ns.Spine and ns.Spine.NetWorthStore) then return end
    local range = RANGES[state.rangeIdx]
    local view = VIEWS[state.viewIdx]
    for i, btn in ipairs(rangeButtons) do btn:SetSelected(i == state.rangeIdx) end
    for i, btn in ipairs(viewButtons)  do btn:SetSelected(i == state.viewIdx)  end

    local now = time()
    local startTime = range.seconds and (now - range.seconds) or nil
    local series = ns.Spine.NetWorthStore:GetSeries(startTime, nil, { includeBound = view.includeBound })

    local points = {}
    for _, p in ipairs(series) do
      points[#points + 1] = { x = p.atTime, y = p.total }
    end
    chart:SetData(points)

    -- Stats footer + per-character table both read from the live snapshot.
    local current = ns.NetWorth:Snapshot({ includeBound = view.includeBound })
    valCurrent:SetText(ns.NetWorth.FormatGold(current.total))
    strategyText:SetText("Strategy: " .. (current.strategy or "—"))

    if #series >= 2 then
      local first, last = series[1], series[#series]
      local d = last.total - first.total
      local sign = d >= 0 and "+" or "-"
      local pct = ""
      if first.total > 0 then
        pct = string.format(" (%s%.1f%%)", sign, math.abs(d / first.total) * 100)
      end
      local r, g, b
      if math.abs(d) < first.total * 0.005 then
        r, g, b = themeColor("textDim", { 0.6, 0.6, 0.6, 1 })
      elseif d >= 0 then
        r, g, b = themeColor("success", { 0.30, 0.85, 0.30, 1 })
      else
        r, g, b = themeColor("error", { 1, 0.25, 0.25, 1 })
      end
      valDelta:SetText(sign .. ns.NetWorth.FormatGold(math.abs(d)) .. pct)
      valDelta:SetTextColor(r, g, b)
    elseif #series == 1 then
      valDelta:SetText("(only 1 snapshot in range)")
      valDelta:SetTextColor(themeColor("textDim", { 0.6, 0.6, 0.6, 1 }))
    else
      valDelta:SetText("(no snapshots in range)")
      valDelta:SetTextColor(themeColor("textDim", { 0.6, 0.6, 0.6, 1 }))
    end

    valSnaps:SetText(tostring(#series))

    -- Per-character table (sorted by total descending). Warband contributes
    -- two synthetic rows (gold + items) instead of one combined entry so
    -- the headline number per row is unambiguously gold OR items — pre-fix
    -- a single "Warband: 37M" row read as "warband gold = 37M" to testers
    -- when the actual breakdown was 29M gold + 8M items (TLY-68). Char
    -- rows stay as one row per character (`total` headline + gold/items
    -- percentage split in the sub-line) since the per-character mental
    -- model is "this character's wealth", not "this character's gold".
    local rows = {}
    for charKey, data in pairs(current.byCharacter or {}) do
      rows[#rows + 1] = {
        key          = charKey,
        kind         = "char",
        total        = data.total,
        gold         = data.gold or 0,
        items        = data.items or 0,
        inventoryKey = charKey,
      }
    end
    if current.warband then
      local wbGold = current.warband.gold or 0
      local wbItems = current.warband.items or 0
      if wbGold > 0 then
        rows[#rows + 1] = {
          key          = "Warband — gold",
          kind         = "warband-gold",
          total        = wbGold,
          inventoryKey = "Warband",
        }
      end
      if wbItems > 0 then
        rows[#rows + 1] = {
          key          = "Warband — items",
          kind         = "warband-items",
          total        = wbItems,
          inventoryKey = "Warband",
        }
      end
    end
    table.sort(rows, function(a, b) return a.total > b.total end)

    local rowHeight = 34
    for i, r in ipairs(rows) do
      local row = getCharRow(i)
      row:SetPoint("TOP", charContent, "TOP", 0, -(i - 1) * rowHeight)
      row._charKey = r.inventoryKey or r.key
      row.name:SetText(r.key)
      row.value:SetText(formatGoldShort(r.total))
      local pctOfTotal = current.total > 0 and (r.total / current.total * 100) or 0
      if r.kind == "warband-gold" then
        row.sub:SetText(string.format(
          "|cff999999%.0f%% of net  -  warband bank gold  -  click for items|r", pctOfTotal))
      elseif r.kind == "warband-items" then
        row.sub:SetText(string.format(
          "|cff999999%.0f%% of net  -  warband bank items  -  click for items|r", pctOfTotal))
      else
        local goldPct = r.total > 0 and (r.gold / r.total * 100) or 0
        row.sub:SetText(string.format("|cff999999%.0f%% of net  -  %.0f%% gold / %.0f%% items  -  click for items|r",
          pctOfTotal, goldPct, 100 - goldPct))
      end
      row:Show()
    end
    for i = #rows + 1, #charRows do charRows[i]:Hide() end
    charContent:SetHeight(math.max(1, #rows * rowHeight))
  end

  return page
end
