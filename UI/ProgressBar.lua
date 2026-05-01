-- Tally — UI/ProgressBar.lua
--
-- Tally-local progress bar widget. Used by the setup wizard's chunked
-- backfill flow (TLY-25) to show "Importing TSM: 47,231 / 90,128 (52%)"
-- live while the user keeps playing. Filed for promotion to a Cogworks
-- primitive in cogworks#23 — once that lands we delete this file and
-- swap callers to cw:CreateProgressBar.
--
-- Public surface:
--   bar = ns.UI.CreateProgressBar(opts)
--     opts: { label, total, parent (optional, defaults to UIParent),
--             onCancel (optional → renders an X), formatFn (optional) }
--   bar:SetTotal(n)
--   bar:SetValue(n)              -- updates fill + label
--   bar:SetLabel(text)            -- mid-task label flip ("Importing TSM (Sales)")
--   bar:Pulse()                  -- indeterminate mode (when total unknown)
--   bar:Complete(label)          -- "Done" flash + fade after 2s
--   bar:Hide()                   -- explicit dismiss
--
-- The widget anchors bottom-right of the screen by default, draggable,
-- position remembered in TallyDB.ui.progressBar across sessions.

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

local DEFAULT_W, DEFAULT_H = 280, 36
local PADDING = 8

function ns.UI.CreateProgressBar(opts)
  opts = opts or {}
  local parent = opts.parent or UIParent

  TallyDB = TallyDB or {}
  TallyDB.ui = TallyDB.ui or {}
  local saved = TallyDB.ui.progressBar
  if type(saved) ~= "table" then
    saved = { x = -20, y = 80, point = "BOTTOMRIGHT", relPoint = "BOTTOMRIGHT" }
    TallyDB.ui.progressBar = saved
  end

  local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
  frame:SetSize(DEFAULT_W, DEFAULT_H)
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

  -- Label.
  local label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("TOPLEFT", frame, "TOPLEFT", PADDING, -PADDING)
  label:SetPoint("RIGHT", frame, "RIGHT", -PADDING - 16, 0)
  label:SetJustifyH("LEFT")
  label:SetWordWrap(false)
  label:SetText(opts.label or "Working…")

  -- Cancel X (optional).
  local cancelBtn
  if opts.onCancel then
    cancelBtn = CreateFrame("Button", nil, frame)
    cancelBtn:SetSize(14, 14)
    cancelBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    local x = cancelBtn:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    x:SetPoint("CENTER")
    x:SetText("X")
    cancelBtn:SetScript("OnClick", function()
      pcall(opts.onCancel)
    end)
  end

  -- Bar frame (track).
  local track = CreateFrame("Frame", nil, frame, "BackdropTemplate")
  track:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", PADDING, PADDING)
  track:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -PADDING, PADDING)
  track:SetHeight(8)
  track:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  track:SetBackdropColor(themeColor("bgLight", { 0.10, 0.10, 0.14, 1 }))
  track:SetBackdropBorderColor(themeColor("border", { 0.25, 0.25, 0.35, 1 }))

  -- Fill.
  local fill = track:CreateTexture(nil, "ARTWORK")
  fill:SetPoint("TOPLEFT", track, "TOPLEFT", 1, -1)
  fill:SetPoint("BOTTOMLEFT", track, "BOTTOMLEFT", 1, 1)
  fill:SetWidth(0)
  fill:SetColorTexture(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  -- Pulse texture (indeterminate mode).
  local pulse = track:CreateTexture(nil, "OVERLAY")
  pulse:SetWidth(40)
  pulse:SetPoint("TOP", track, "TOP", 0, -1)
  pulse:SetPoint("BOTTOM", track, "BOTTOM", 0, 1)
  pulse:SetColorTexture(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))
  pulse:SetAlpha(0.6)
  pulse:Hide()

  local total = tonumber(opts.total) or 0
  local value = 0
  local pulseTicker = nil
  local pulsePos = 0

  local function defaultFormat(done, t)
    if t == 0 then return label:GetText() or "" end
    return string.format("%s — %s / %s (%d%%)",
      opts.label or "",
      formatGroup(done), formatGroup(t),
      math.floor(done / math.max(t, 1) * 100))
  end
  local function applyLabel()
    if opts.formatFn then
      label:SetText(opts.formatFn(value, total))
    else
      label:SetText(defaultFormat(value, total))
    end
  end

  local function applyFill()
    if total <= 0 then
      fill:SetWidth(0)
      return
    end
    local w = (track:GetWidth() - 2) * math.min(value / total, 1)
    fill:SetWidth(math.max(0, w))
  end

  local function stopPulse()
    if pulseTicker and pulseTicker.Cancel then pulseTicker:Cancel() end
    pulseTicker = nil
    pulse:Hide()
  end

  local bar = {}

  function bar:SetTotal(n)
    total = tonumber(n) or 0
    stopPulse()
    fill:Show()
    applyFill()
    applyLabel()
  end

  function bar:SetValue(n)
    value = tonumber(n) or 0
    if total <= 0 then total = value end
    stopPulse()
    fill:Show()
    applyFill()
    applyLabel()
  end

  function bar:SetLabel(text)
    if opts.formatFn then
      opts.label = text
      applyLabel()
    else
      label:SetText(text)
    end
  end

  -- Indeterminate mode: a 40px highlight slides across the track. Used
  -- when total is unknown (e.g., a parse phase whose row count we don't
  -- know up-front).
  function bar:Pulse()
    fill:Hide()
    pulse:Show()
    if pulseTicker or not C_Timer then return end
    pulsePos = 0
    pulseTicker = C_Timer.NewTicker(0.05, function()
      local trackW = track:GetWidth() - 2
      pulsePos = pulsePos + 8
      if pulsePos > trackW then pulsePos = -40 end
      pulse:ClearAllPoints()
      pulse:SetPoint("LEFT", track, "LEFT", pulsePos, 0)
    end)
  end

  function bar:Complete(text)
    stopPulse()
    if total > 0 then value = total end
    fill:Show()
    applyFill()
    label:SetText(text or "Done.")
    if C_Timer and C_Timer.After then
      C_Timer.After(2, function()
        if frame and frame:IsShown() then frame:Hide() end
      end)
    end
  end

  function bar:Hide()
    stopPulse()
    frame:Hide()
  end

  function bar:Show()
    frame:Show()
  end

  function bar:GetFrame() return frame end

  -- Initial render.
  if total > 0 then
    applyLabel()
    applyFill()
  else
    bar:Pulse()
  end

  return bar
end
