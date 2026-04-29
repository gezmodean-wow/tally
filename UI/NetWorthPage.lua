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

function ns.UI.CreateNetWorthPage(parent)
  local page = CreateFrame("Frame", nil, parent)
  local state = { rangeIdx = 2 } -- default: 30d

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

  local strategyText = controlRow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  strategyText:SetPoint("RIGHT", controlRow, "RIGHT", -2, 0)
  strategyText:SetJustifyH("RIGHT")

  -- Chart.
  local chart = ns.UI.CreateLineChart(page, {
    yLabelWidth = 72,
    xLabelHeight = 16,
    yTicks = 4,
    xTicks = 5,
  })
  chart:SetPoint("TOPLEFT", controlRow, "BOTTOMLEFT", 0, -8)
  chart:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 60)

  chart:SetYFormatter(function(copper)
    return formatGoldShort(copper)
  end)
  chart:SetXFormatter(function(epoch)
    return date("%m/%d", epoch)
  end)

  -- Stats footer.
  local footer = CreateFrame("Frame", nil, page)
  footer:SetPoint("TOPLEFT", chart, "BOTTOMLEFT", 0, -8)
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
    if not (ns.History and ns.History.GetNetWorthSeries) then return end
    local range = RANGES[state.rangeIdx]
    for i, btn in ipairs(rangeButtons) do btn:SetSelected(i == state.rangeIdx) end

    local now = time()
    local startTime = range.seconds and (now - range.seconds) or nil
    local series = ns.History:GetNetWorthSeries(startTime, nil, { includeBound = false })

    local points = {}
    for _, p in ipairs(series) do
      points[#points + 1] = { x = p.atTime, y = p.total }
    end
    chart:SetData(points)

    -- Stats footer.
    local current = ns.NetWorth:Snapshot()
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
  end

  return page
end
