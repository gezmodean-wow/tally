-- Tally — UI/MultiProgressBar.lua
--
-- Stacked per-source progress widget. Used by the setup wizard's
-- chunked backfill flow so the user sees every source's progress
-- simultaneously instead of one bar that gets relabeled four times.
--
-- Public surface:
--   panel = ns.UI.CreateMultiProgress(opts)
--     opts: { sources = { { name, label }, ... }, title (optional),
--             parent (default UIParent), onCancel (optional) }
--   panel:Show() / panel:Hide()
--   panel:GetBar(name)
--     bar:SetState("queued" | "importing" | "done" | "error" | "skipped")
--     bar:SetTotal(n)
--     bar:SetValue(n)
--     bar:Complete(insertedCount, skippedCount)
--   panel:Complete(text)   -- final summary line + fade after 4s
--
-- Position persists at TallyDB.ui.multiProgress across sessions.

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

local function formatGroup(n)
  if BreakUpLargeNumbers then return BreakUpLargeNumbers(n) end
  return tostring(n)
end

local PANEL_W = 320
local PAD = 10
local TITLE_H = 18
local FOOTER_H = 18
local BAR_H = 38       -- per-source row height (label + bar)
local BAR_FILL_H = 6
local STATE_COLORS = {
  queued    = function() return themeColor("textDim", { 0.6, 0.6, 0.6, 1 }) end,
  importing = function() return themeColor("brass", { 0.83, 0.63, 0.09, 1 }) end,
  done      = function() return themeColor("success", { 0.30, 0.85, 0.30, 1 }) end,
  error     = function() return themeColor("error", { 1, 0.25, 0.25, 1 }) end,
  skipped   = function() return themeColor("textDim", { 0.5, 0.5, 0.5, 1 }) end,
}

local STATE_LABEL = {
  queued    = "queued",
  importing = "importing",
  done      = "done",
  error     = "error",
  skipped   = "skipped",
}

local function makeBar(parent, sourceLabel, yOffset)
  local bar = {}

  local row = CreateFrame("Frame", nil, parent)
  row:SetHeight(BAR_H)
  row:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD, -yOffset)
  row:SetPoint("RIGHT", parent, "RIGHT", -PAD, 0)
  bar._row = row

  -- Top line: source label + state/percent.
  local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
  label:SetText(sourceLabel)
  label:SetWidth(150)
  label:SetJustifyH("LEFT")

  local stateText = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  stateText:SetPoint("TOPRIGHT", row, "TOPRIGHT", 0, 0)
  stateText:SetJustifyH("RIGHT")

  -- Track + fill.
  local track = CreateFrame("Frame", nil, row, "BackdropTemplate")
  track:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
  track:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
  track:SetHeight(BAR_FILL_H)
  track:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  track:SetBackdropColor(themeColor("bgLight", { 0.10, 0.10, 0.14, 1 }))
  track:SetBackdropBorderColor(themeColor("border", { 0.25, 0.25, 0.35, 1 }))

  local fill = track:CreateTexture(nil, "ARTWORK")
  fill:SetPoint("TOPLEFT", track, "TOPLEFT", 1, -1)
  fill:SetPoint("BOTTOMLEFT", track, "BOTTOMLEFT", 1, 1)
  fill:SetWidth(0)

  local total, value = 0, 0
  local state = "queued"

  local function applyFill()
    if total <= 0 then fill:SetWidth(0); return end
    local w = (track:GetWidth() - 2) * math.min(value / total, 1)
    fill:SetWidth(math.max(0, w))
  end

  local function applyColor()
    local r, g, b, a = STATE_COLORS[state]()
    fill:SetColorTexture(r, g, b, a or 1)
    stateText:SetTextColor(r, g, b, a or 1)
  end

  local function applyStateText()
    if state == "importing" then
      if total > 0 then
        stateText:SetText(string.format("%s / %s (%d%%)",
          formatGroup(value), formatGroup(total),
          math.floor(value / math.max(total, 1) * 100)))
      else
        stateText:SetText("importing…")
      end
    elseif state == "done" then
      stateText:SetText(string.format("done — %s imported", formatGroup(value)))
    else
      stateText:SetText(STATE_LABEL[state] or state)
    end
  end

  function bar:SetState(s)
    state = s or "queued"
    applyColor()
    applyStateText()
  end

  function bar:SetTotal(n)
    total = tonumber(n) or 0
    applyFill()
    applyStateText()
  end

  function bar:SetValue(n)
    value = tonumber(n) or 0
    if value > 0 and state == "queued" then
      state = "importing"
      applyColor()
    end
    applyFill()
    applyStateText()
  end

  function bar:Complete(inserted, skipped)
    state = "done"
    value = inserted or value
    if total <= 0 then total = value end
    applyFill()
    applyColor()
    applyStateText()
  end

  function bar:GetHeight() return BAR_H end

  -- Initial.
  bar:SetState("queued")
  return bar
end

function ns.UI.CreateMultiProgress(opts)
  opts = opts or {}
  local sources = opts.sources or {}
  local parent = opts.parent or UIParent

  TallyDB = TallyDB or {}
  TallyDB.ui = TallyDB.ui or {}
  local saved = TallyDB.ui.multiProgress
  if type(saved) ~= "table" then
    saved = { x = -20, y = 80, point = "BOTTOMRIGHT", relPoint = "BOTTOMRIGHT" }
    TallyDB.ui.multiProgress = saved
  end

  local panelHeight = PAD + TITLE_H + 4 + (BAR_H + 8) * #sources + FOOTER_H + PAD
  local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  frame:SetSize(PANEL_W, panelHeight)
  frame:SetFrameStrata("DIALOG")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetClampedToScreen(true)
  frame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  frame:SetBackdropColor(themeColor("bgDark", { 0.04, 0.04, 0.07, 0.95 }))
  frame:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))
  frame:SetPoint(saved.point or "BOTTOMRIGHT", parent,
    saved.relPoint or "BOTTOMRIGHT", saved.x or -20, saved.y or 80)

  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint(1)
    saved.point = point
    saved.relPoint = relPoint
    saved.x = x
    saved.y = y
  end)

  -- Title.
  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD)
  title:SetText(opts.title or "Importing")
  title:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  -- Optional cancel X.
  if opts.onCancel then
    local btn = CreateFrame("Button", nil, frame)
    btn:SetSize(14, 14)
    btn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    local x = btn:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    x:SetPoint("CENTER")
    x:SetText("X")
    btn:SetScript("OnClick", function() pcall(opts.onCancel) end)
  end

  -- Per-source bars, stacked at fixed y offsets from the panel top.
  -- Each bar is BAR_H + 8px gap. yStart accounts for top padding + the
  -- title row height.
  local bars = {}
  local yStart = PAD + TITLE_H + 8
  for i, s in ipairs(sources) do
    local yOff = yStart + (i - 1) * (BAR_H + 8)
    local bar = makeBar(frame, s.label or s.name, yOff)
    bars[s.name] = bar
    bars[#bars + 1] = bar  -- ordered list too
  end

  -- Footer status line (bottom of panel).
  local footer = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  footer:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PAD, PAD)
  footer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PAD, PAD)
  footer:SetJustifyH("LEFT")
  footer:SetText("Waiting to start…")

  local panel = {}

  function panel:GetBar(name)
    return bars[name]
  end

  function panel:Show() frame:Show() end
  function panel:Hide() frame:Hide() end
  function panel:GetFrame() return frame end

  function panel:SetFooter(text)
    footer:SetText(text or "")
  end

  function panel:Complete(text)
    if text then footer:SetText(text) end
    if C_Timer and C_Timer.After then
      C_Timer.After(4, function()
        if frame and frame:IsShown() then frame:Hide() end
      end)
    end
  end

  return panel
end
