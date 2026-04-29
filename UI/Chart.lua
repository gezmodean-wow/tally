-- Tally — UI/Chart.lua
--
-- Reusable pure-Lua line chart. Backed by Frame:CreateLine() (modern client
-- API). One Line region per segment between consecutive points; segments are
-- pooled across refreshes so re-rendering doesn't accumulate texture regions.
--
-- Public surface:
--   chart = ns.UI.CreateLineChart(parent, opts)
--   chart:SetSize(width, height)
--   chart:SetData(points, dataOpts)   -- points = { { x = N, y = copper }, ... }
--   chart:SetXFormatter(fn)           -- fn(x) -> "label" for x-axis ticks
--   chart:SetYFormatter(fn)           -- fn(y) -> "label" for y-axis ticks
--   chart:Refresh()
--
-- opts:
--   xPadLeft  / xPadRight (numbers; default 8)
--   yPadTop   / yPadBottom (numbers; default 6)
--   yLabelWidth (default 64) — reserved space on the left for value labels
--   xLabelHeight (default 14) — reserved space at the bottom for time labels
--   yTicks / xTicks (number of grid divisions; defaults 4 / 5)
--   lineColor / gridColor / labelColor (RGBA tables; defaults from Cogworks theme)
--   thickness (line thickness in pixels; default 2)
--   minimal (bool) — sparkline mode: zero label space, no grid, no tick labels.
--                    Useful for inline sparklines in research views.

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

local DEFAULTS = {
  xPadLeft = 8, xPadRight = 8, yPadTop = 6, yPadBottom = 6,
  yLabelWidth = 64, xLabelHeight = 14,
  yTicks = 4, xTicks = 5,
  thickness = 2,
}

function ns.UI.CreateLineChart(parent, opts)
  opts = opts or {}
  for k, v in pairs(DEFAULTS) do
    if opts[k] == nil then opts[k] = v end
  end
  if opts.minimal then
    opts.yLabelWidth = 0
    opts.xLabelHeight = 0
    opts.yTicks = 0
    opts.xTicks = 0
  end

  local frame = CreateFrame("Frame", nil, parent)
  frame:SetSize(opts.width or 320, opts.height or 160)

  -- Plot region (insets account for axis labels).
  local plot = CreateFrame("Frame", nil, frame)
  plot:SetPoint("TOPLEFT", frame, "TOPLEFT", opts.yLabelWidth, -opts.yPadTop)
  plot:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -opts.xPadRight, opts.xLabelHeight)

  -- Plot background (subtle, helps perceive bounds).
  local bg = plot:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(themeColor("bgDark", { 0.04, 0.04, 0.07, 0.6 }))

  -- Pools — segments and tick labels and grid lines are reused across refreshes.
  local segments = {}      -- list of Line regions
  local segUsed = 0
  local gridLines = {}     -- list of Line regions for grid
  local gridUsed = 0
  local yLabels = {}       -- FontStrings for y-axis labels
  local yLabelUsed = 0
  local xLabels = {}       -- FontStrings for x-axis labels
  local xLabelUsed = 0

  local function acquireSegment()
    segUsed = segUsed + 1
    local s = segments[segUsed]
    if not s then
      s = plot:CreateLine(nil, "OVERLAY")
      s:SetThickness(opts.thickness)
      segments[segUsed] = s
    end
    s:Show()
    return s
  end

  local function acquireGrid()
    gridUsed = gridUsed + 1
    local g = gridLines[gridUsed]
    if not g then
      g = plot:CreateLine(nil, "BACKGROUND", nil, 1)
      g:SetThickness(1)
      gridLines[gridUsed] = g
    end
    g:Show()
    return g
  end

  local function acquireYLabel()
    yLabelUsed = yLabelUsed + 1
    local fs = yLabels[yLabelUsed]
    if not fs then
      fs = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      fs:SetJustifyH("RIGHT")
      yLabels[yLabelUsed] = fs
    end
    fs:Show()
    return fs
  end

  local function acquireXLabel()
    xLabelUsed = xLabelUsed + 1
    local fs = xLabels[xLabelUsed]
    if not fs then
      fs = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      fs:SetJustifyH("CENTER")
      xLabels[xLabelUsed] = fs
    end
    fs:Show()
    return fs
  end

  local function hideUnused()
    for i = segUsed + 1, #segments do segments[i]:Hide() end
    for i = gridUsed + 1, #gridLines do gridLines[i]:Hide() end
    for i = yLabelUsed + 1, #yLabels do yLabels[i]:Hide() end
    for i = xLabelUsed + 1, #xLabels do xLabels[i]:Hide() end
  end

  local data = {}                      -- list of { x, y }
  local dataOpts = {}                  -- xMin, xMax, yMin, yMax overrides
  local xFormatter = function(x) return tostring(x) end
  local yFormatter = function(y) return tostring(y) end

  -- Public API ---------------------------------------------------------------

  -- Auto-refresh on size changes so consumers can drive the layout without
  -- knowing they need to call :Refresh() afterward.
  frame:SetScript("OnSizeChanged", function(self) self:Refresh() end)

  function frame:SetData(points, dOpts)
    data = points or {}
    dataOpts = dOpts or {}
    self:Refresh()
  end

  function frame:SetXFormatter(fn) xFormatter = fn or xFormatter; self:Refresh() end
  function frame:SetYFormatter(fn) yFormatter = fn or yFormatter; self:Refresh() end

  function frame:GetPlot() return plot end

  -- Refresh draws axes, grid, labels, and segments. Called automatically by
  -- SetData / SetSize / SetXFormatter / SetYFormatter.
  function frame:Refresh()
    segUsed, gridUsed, yLabelUsed, xLabelUsed = 0, 0, 0, 0

    if #data == 0 then
      hideUnused()
      return
    end

    -- Compute bounds from data with optional overrides.
    local xMin = dataOpts.xMin or data[1].x
    local xMax = dataOpts.xMax or data[#data].x
    if xMax == xMin then xMax = xMin + 1 end

    local yMin = dataOpts.yMin
    local yMax = dataOpts.yMax
    if not yMin or not yMax then
      local lo, hi = math.huge, -math.huge
      for _, p in ipairs(data) do
        if p.y < lo then lo = p.y end
        if p.y > hi then hi = p.y end
      end
      yMin = yMin or math.floor(lo)
      yMax = yMax or math.ceil(hi)
      if yMin == yMax then
        -- Flat data: pad ±1 so the line sits in the middle, not on the edge.
        yMin, yMax = yMin - 1, yMax + 1
      else
        local pad = (yMax - yMin) * 0.05
        yMin = math.max(0, yMin - pad)
        yMax = yMax + pad
      end
    end

    local plotW = plot:GetWidth()
    local plotH = plot:GetHeight()
    if plotW <= 0 or plotH <= 0 then
      hideUnused(); return
    end

    local function px(x) return ((x - xMin) / (xMax - xMin)) * plotW end
    local function py(y) return ((y - yMin) / (yMax - yMin)) * plotH end

    -- Axes & labels (skipped in minimal/sparkline mode).
    if opts.yTicks > 0 then
      local gr, gg, gb, ga = themeColor("border", { 0.30, 0.30, 0.40, 0.4 })
      ga = (ga or 1) * 0.4 -- soften grid
      local lr, lg, lb, la = themeColor("textDim", { 0.6, 0.6, 0.6, 1 })

      for i = 0, opts.yTicks do
        local f = i / opts.yTicks
        local y = yMin + (yMax - yMin) * f
        local yPx = py(y)
        local g = acquireGrid()
        g:SetColorTexture(gr, gg, gb, ga)
        g:SetStartPoint("BOTTOMLEFT", plot, 0, yPx)
        g:SetEndPoint("BOTTOMLEFT", plot, plotW, yPx)
        if opts.yLabelWidth > 0 then
          local fs = acquireYLabel()
          fs:ClearAllPoints()
          fs:SetPoint("RIGHT", plot, "BOTTOMLEFT", -4, yPx)
          fs:SetWidth(opts.yLabelWidth - 4)
          fs:SetText(yFormatter(y))
          fs:SetTextColor(lr, lg, lb, la)
        end
      end
    end

    if opts.xTicks > 0 and opts.xLabelHeight > 0 then
      local lr, lg, lb, la = themeColor("textDim", { 0.6, 0.6, 0.6, 1 })
      for i = 0, opts.xTicks do
        local f = i / opts.xTicks
        local x = xMin + (xMax - xMin) * f
        local xPx = px(x)
        local fs = acquireXLabel()
        fs:ClearAllPoints()
        fs:SetPoint("TOP", plot, "BOTTOMLEFT", xPx, -2)
        fs:SetText(xFormatter(x))
        fs:SetTextColor(lr, lg, lb, la)
      end
    end

    -- Line segments.
    local cr, cg, cb, ca = themeColor("gold", { 1, 0.82, 0, 1 })
    for i = 1, #data - 1 do
      local p1 = data[i]
      local p2 = data[i + 1]
      local s = acquireSegment()
      s:SetColorTexture(cr, cg, cb, ca)
      s:SetStartPoint("BOTTOMLEFT", plot, px(p1.x), py(p1.y))
      s:SetEndPoint("BOTTOMLEFT", plot, px(p2.x), py(p2.y))
    end

    hideUnused()
  end

  return frame
end
