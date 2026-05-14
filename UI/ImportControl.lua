-- Tally — UI/ImportControl.lua
--
-- TLY-71's persistent control widget for the chunked-import driver. Always-on-
-- top, draggable, listener-wired to ns.Import. Surfaces in-flight backfill
-- progress + offers live pause/resume/cancel + budget/delay tuning without
-- having to type `/tally import` for every adjustment.
--
-- Lifecycle is event-driven: Show() makes the singleton visible and registers
-- a listener with ns.Import; every controller phase change re-renders the
-- widget. Phase=="done" auto-fades after a brief delay; "errored" + "cancelled"
-- stay visible so the player can read the result and Resume if desired.
--
-- Minimised mode collapses to a compact badge near the minimap. Expanded and
-- minimised positions persist independently in TallyDB.ui.importController.

local addonName, ns = ...
ns.UI = ns.UI or {}

local Control = {}
ns.UI.ImportControl = Control

-- ============================================================================
-- Helpers
-- ============================================================================

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

local function fmtGroup(n)
  if BreakUpLargeNumbers then return BreakUpLargeNumbers(n) end
  return tostring(n)
end

-- "~3m 20s" / "~45s" / "~1h 5m". For the per-source ETA line and the footer
-- aggregate. Anything under 5s rounds to "<5s" so the value stops twitching
-- on the final cycle.
local function fmtDuration(sec)
  sec = math.max(0, math.floor(sec or 0))
  if sec < 5 then return "<5s" end
  if sec < 60 then return string.format("%ds", sec) end
  local m = math.floor(sec / 60)
  local s = sec % 60
  if m < 60 then
    if s == 0 then return string.format("%dm", m) end
    return string.format("%dm %ds", m, s)
  end
  local h = math.floor(m / 60)
  m = m % 60
  if m == 0 then return string.format("%dh", h) end
  return string.format("%dh %dm", h, m)
end

-- ============================================================================
-- State + saved position
-- ============================================================================

local PANEL_W       = 360
local PAD           = 10
local TITLE_H       = 18
local ROW_H         = 38
local ROW_GAP       = 8
local BAR_FILL_H    = 6
local SEPARATOR_H   = 8
local CONTROL_H     = 50            -- inputs + buttons stacked
local BADGE_SIZE    = 28

local STATE_COLOR_KEYS = {
  queued    = { "textDim", { 0.60, 0.60, 0.60, 1 } },
  importing = { "brass",   { 0.83, 0.63, 0.09, 1 } },
  done      = { "success", { 0.30, 0.85, 0.30, 1 } },
  error     = { "error",   { 1.00, 0.25, 0.25, 1 } },
  skipped   = { "textDim", { 0.50, 0.50, 0.50, 1 } },
  paused    = { "textDim", { 0.70, 0.70, 0.70, 1 } },
}

local function ensureSavedPosition()
  TallyDB = TallyDB or {}
  TallyDB.ui = TallyDB.ui or {}
  local saved = TallyDB.ui.importController
  if type(saved) ~= "table" then
    saved = {}
    TallyDB.ui.importController = saved
  end
  saved.expanded = saved.expanded or {
    point = "BOTTOMRIGHT", relPoint = "BOTTOMRIGHT", x = -20, y = 120,
  }
  saved.minimised = saved.minimised or {
    point = "BOTTOMRIGHT", relPoint = "BOTTOMRIGHT", x = -20, y = 120,
  }
  if saved.mode ~= "minimised" then saved.mode = "expanded" end
  return saved
end

-- Singleton frame handles + listener token.
local frame, badge
local titleText, sourceArea, footerText, budgetEdit, delayEdit
local pauseBtn, resumeBtn, cancelBtn
local rows = {}                 -- rows[sourceName] = { ...widgets... }
local rowOrder = {}             -- preserve config.sources order
local listenerHandle = "TallyImportControl"
local autoHideTimer            -- pending C_Timer.After handle for done-fade
local suppressInputCommit = false

-- ============================================================================
-- Per-source row rendering
-- ============================================================================

local function applyRowState(row, state)
  local colorEntry = STATE_COLOR_KEYS[state] or STATE_COLOR_KEYS.queued
  local r, g, b, a = themeColor(colorEntry[1], colorEntry[2])
  row.fill:SetColorTexture(r, g, b, a or 1)
  row.stateText:SetTextColor(r, g, b, a or 1)
end

local function setRowProgress(row, inserted, total)
  inserted = inserted or 0
  total = total or 0
  if total <= 0 then
    row.fill:SetWidth(0)
    return
  end
  local trackW = row.track:GetWidth() - 2
  local w = trackW * math.min(inserted / math.max(total, 1), 1)
  row.fill:SetWidth(math.max(0, w))
end

local function createRow(parent, sourceName, label, yOffset)
  local row = { name = sourceName }

  local container = CreateFrame("Frame", nil, parent)
  container:SetHeight(ROW_H)
  container:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -yOffset)
  container:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
  row.container = container

  row.label = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.label:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
  row.label:SetWidth(140)
  row.label:SetJustifyH("LEFT")
  row.label:SetText(label or sourceName)

  row.stateText = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  row.stateText:SetPoint("TOPLEFT", row.label, "TOPRIGHT", 8, 0)
  row.stateText:SetPoint("RIGHT", container, "RIGHT", 0, 0)
  row.stateText:SetJustifyH("RIGHT")
  row.stateText:SetText("queued")

  -- Track + fill at the bottom of the row.
  row.track = CreateFrame("Frame", nil, container, "BackdropTemplate")
  row.track:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, 0)
  row.track:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
  row.track:SetHeight(BAR_FILL_H)
  row.track:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  row.track:SetBackdropColor(themeColor("bgLight", { 0.10, 0.10, 0.14, 1 }))
  row.track:SetBackdropBorderColor(themeColor("border", { 0.25, 0.25, 0.35, 1 }))

  row.fill = row.track:CreateTexture(nil, "ARTWORK")
  row.fill:SetPoint("TOPLEFT", row.track, "TOPLEFT", 1, -1)
  row.fill:SetPoint("BOTTOMLEFT", row.track, "BOTTOMLEFT", 1, 1)
  row.fill:SetWidth(0)

  applyRowState(row, "queued")
  return row
end

-- ============================================================================
-- Frame construction
-- ============================================================================

local function applySavedPoint(target, saved)
  target:ClearAllPoints()
  target:SetPoint(saved.point or "BOTTOMRIGHT", UIParent,
    saved.relPoint or "BOTTOMRIGHT", saved.x or -20, saved.y or 120)
end

local function persistDragPoint(target, saved)
  local point, _, relPoint, x, y = target:GetPoint(1)
  saved.point = point
  saved.relPoint = relPoint
  saved.x = x
  saved.y = y
end

local function makeButton(parent, label, width, onClick)
  local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  btn:SetSize(width or 70, 22)
  btn:SetText(label)
  btn:SetScript("OnClick", function() pcall(onClick) end)
  return btn
end

local function makeNumericInput(parent, width)
  local input = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  input:SetSize(width or 60, 18)
  input:SetAutoFocus(false)
  input:SetNumeric(false)            -- allow decimals for delay
  input:SetMaxLetters(8)
  input:SetFontObject("GameFontHighlightSmall")
  return input
end

local function showCancelConfirm()
  StaticPopupDialogs["TALLY_IMPORT_CANCEL"] = StaticPopupDialogs["TALLY_IMPORT_CANCEL"] or {
    text = "Stop the backfill?\n\nProgress is preserved — you can resume later from this widget or /tally import resume.",
    button1 = "Stop",
    button2 = "Keep going",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function()
      if ns.Import and ns.Import.Cancel then ns.Import:Cancel() end
    end,
  }
  StaticPopup_Show("TALLY_IMPORT_CANCEL")
end

-- Build the badge once; click restores the expanded frame.
local function createBadge()
  if badge then return badge end
  local saved = ensureSavedPosition().minimised
  badge = CreateFrame("Button", nil, UIParent, "BackdropTemplate")
  badge:SetSize(BADGE_SIZE, BADGE_SIZE)
  badge:SetFrameStrata("MEDIUM")
  badge:SetMovable(true)
  badge:EnableMouse(true)
  badge:RegisterForDrag("LeftButton")
  badge:SetClampedToScreen(true)
  badge:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  badge:SetBackdropColor(themeColor("bgDark", { 0.04, 0.04, 0.07, 0.95 }))
  badge:SetBackdropBorderColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))
  applySavedPoint(badge, saved)

  local pct = badge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  pct:SetPoint("CENTER")
  pct:SetText("…")
  pct:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))
  badge.pctText = pct

  badge:SetScript("OnDragStart", function(self) self:StartMoving() end)
  badge:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    persistDragPoint(self, saved)
  end)
  badge:SetScript("OnClick", function()
    Control:Restore()
  end)
  badge:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Tally backfill", 1, 1, 1)
    GameTooltip:AddLine("Click to restore the import controller.", 0.7, 0.7, 0.7, true)
    GameTooltip:Show()
  end)
  badge:SetScript("OnLeave", function() GameTooltip:Hide() end)
  badge:Hide()
  return badge
end

local function createFrame()
  if frame then return frame end
  local saved = ensureSavedPosition().expanded

  frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  frame:SetSize(PANEL_W, 200)        -- height computed in renderRows
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
  applySavedPoint(frame, saved)

  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    persistDragPoint(self, saved)
  end)

  titleText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  titleText:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -PAD)
  titleText:SetText("Importing from siblings")
  titleText:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  -- Minimise (_) button — collapses to badge.
  local minBtn = CreateFrame("Button", nil, frame)
  minBtn:SetSize(14, 14)
  minBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -22, -6)
  local minText = minBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  minText:SetPoint("CENTER", minBtn, "CENTER", 0, 2)
  minText:SetText("_")
  minText:SetTextColor(themeColor("textDim", { 0.7, 0.7, 0.7, 1 }))
  minBtn:SetScript("OnClick", function() Control:Minimise() end)
  minBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Minimise", 1, 1, 1)
    GameTooltip:Show()
  end)
  minBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- X button — confirm-popup cancel that preserves pending state.
  local closeBtn = CreateFrame("Button", nil, frame)
  closeBtn:SetSize(14, 14)
  closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -6)
  local xText = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  xText:SetPoint("CENTER")
  xText:SetText("X")
  xText:SetTextColor(themeColor("textDim", { 0.7, 0.7, 0.7, 1 }))
  closeBtn:SetScript("OnClick", function() showCancelConfirm() end)
  closeBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("Stop backfill (resumable)", 1, 1, 1)
    GameTooltip:Show()
  end)
  closeBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  -- Container for per-source rows. Resized by renderRows.
  sourceArea = CreateFrame("Frame", nil, frame)
  sourceArea:SetPoint("TOPLEFT", frame, "TOPLEFT", PAD, -(PAD + TITLE_H + 6))
  sourceArea:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
  sourceArea:SetHeight(ROW_H)

  -- Controls row 1: budget + delay inputs.
  local controlRow1 = CreateFrame("Frame", nil, frame)
  controlRow1:SetHeight(22)
  controlRow1:SetPoint("TOPLEFT", sourceArea, "BOTTOMLEFT", 0, -SEPARATOR_H)
  controlRow1:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)

  local budgetLbl = controlRow1:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  budgetLbl:SetPoint("LEFT", controlRow1, "LEFT", 0, 0)
  budgetLbl:SetText("Budget:")

  budgetEdit = makeNumericInput(controlRow1, 56)
  budgetEdit:SetPoint("LEFT", budgetLbl, "RIGHT", 8, 0)

  local budgetSuffix = controlRow1:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  budgetSuffix:SetPoint("LEFT", budgetEdit, "RIGHT", 6, 0)
  budgetSuffix:SetText("rows / cycle")

  local delayLbl = controlRow1:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  delayLbl:SetPoint("LEFT", budgetSuffix, "RIGHT", 14, 0)
  delayLbl:SetText("every")

  delayEdit = makeNumericInput(controlRow1, 36)
  delayEdit:SetPoint("LEFT", delayLbl, "RIGHT", 8, 0)

  local delaySuffix = controlRow1:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  delaySuffix:SetPoint("LEFT", delayEdit, "RIGHT", 4, 0)
  delaySuffix:SetText("s")

  local function commitBudget()
    if suppressInputCommit then return end
    local n = tonumber(budgetEdit:GetText())
    if n and n > 0 and ns.Import and ns.Import.UpdateBudget then
      ns.Import:UpdateBudget(math.floor(n), nil)
    end
    budgetEdit:ClearFocus()
  end
  local function commitDelay()
    if suppressInputCommit then return end
    local n = tonumber(delayEdit:GetText())
    if n and n > 0 and ns.Import and ns.Import.UpdateBudget then
      ns.Import:UpdateBudget(nil, n)
    end
    delayEdit:ClearFocus()
  end
  budgetEdit:SetScript("OnEnterPressed", commitBudget)
  budgetEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  budgetEdit:SetScript("OnEditFocusLost", commitBudget)
  delayEdit:SetScript("OnEnterPressed", commitDelay)
  delayEdit:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  delayEdit:SetScript("OnEditFocusLost", commitDelay)

  -- Controls row 2: Pause / Resume / Cancel buttons.
  local controlRow2 = CreateFrame("Frame", nil, frame)
  controlRow2:SetHeight(22)
  controlRow2:SetPoint("TOPLEFT", controlRow1, "BOTTOMLEFT", 0, -4)
  controlRow2:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)

  pauseBtn = makeButton(controlRow2, "Pause", 70, function()
    if ns.Import and ns.Import.Pause then ns.Import:Pause() end
  end)
  pauseBtn:SetPoint("LEFT", controlRow2, "LEFT", 0, 0)

  resumeBtn = makeButton(controlRow2, "Resume", 70, function()
    if ns.Import and ns.Import.Resume then ns.Import:Resume() end
  end)
  resumeBtn:SetPoint("LEFT", pauseBtn, "RIGHT", 6, 0)

  cancelBtn = makeButton(controlRow2, "Cancel", 70, showCancelConfirm)
  cancelBtn:SetPoint("RIGHT", controlRow2, "RIGHT", 0, 0)

  -- Footer aggregate line.
  footerText = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  footerText:SetPoint("TOPLEFT", controlRow2, "BOTTOMLEFT", 0, -6)
  footerText:SetPoint("RIGHT", frame, "RIGHT", -PAD, 0)
  footerText:SetJustifyH("LEFT")
  footerText:SetText("")

  frame:Hide()
  return frame
end

-- ============================================================================
-- Rendering
-- ============================================================================

local function clearRows()
  for _, row in pairs(rows) do
    if row.container then
      row.container:Hide()
      row.container:SetParent(nil)
    end
  end
  rows = {}
  rowOrder = {}
end

-- Build a row per configured source. Called on initial render + whenever the
-- controller's source set changes (a new Start with different sources).
local function rebuildRows(state)
  clearRows()
  local sources = (state.config and state.config.sources) or {}
  for i, name in ipairs(sources) do
    local label = name
    if ns.Ledger and ns.Ledger.GetSources then
      for _, s in ipairs(ns.Ledger:GetSources()) do
        if s.name == name then label = s.label or name; break end
      end
    end
    local yOffset = (i - 1) * (ROW_H + ROW_GAP)
    local row = createRow(sourceArea, name, label, yOffset)
    rows[name] = row
    rowOrder[#rowOrder + 1] = name
  end
  -- Resize source area to fit rows.
  local h = math.max(ROW_H, #sources * (ROW_H + ROW_GAP) - ROW_GAP)
  sourceArea:SetHeight(h)

  -- Frame height: top pad + title + sources + separator + controls (2 rows + footer).
  local frameH = PAD + TITLE_H + 6 + h + SEPARATOR_H + 22 + 4 + 22 + 6 + 14 + PAD
  frame:SetHeight(frameH)
end

-- Compute ETA in seconds for the current source: remaining rows / rate.
-- Rate is derived from configured budget+delay (rather than measured throughput)
-- because the importer's outer cadence is the actual gating factor; measured
-- throughput is noisy at slice granularity and matches the configured cadence
-- by construction on average.
local function estimateCurrentEta(state)
  local c = state.current
  if not c or (c.total or 0) <= 0 then return nil end
  local remaining = math.max(0, (c.total or 0) - (c.idx or 0))
  if remaining == 0 then return 0 end
  local budget = (state.config and state.config.budgetRows) or 10000
  local delay  = (state.config and state.config.delaySec)   or 2.0
  if budget <= 0 then return nil end
  local cycles = math.ceil(remaining / budget)
  return cycles * delay
end

local function updateRow(name, state)
  local row = rows[name]
  if not row then return end

  -- Find a matching results[] entry (done/skipped/errored already).
  local result
  for _, r in ipairs(state.results or {}) do
    if r.source == name then result = r; break end
  end

  if result then
    if result.skippedSource then
      applyRowState(row, "skipped")
      row.stateText:SetText(string.format("skipped (%s)", result.reason or "?"))
      setRowProgress(row, 0, 0)
      return
    end
    applyRowState(row, "done")
    row.stateText:SetText(string.format("done — %s imported", fmtGroup(result.inserted or 0)))
    setRowProgress(row, 1, 1)
    return
  end

  -- Currently importing this source?
  if state.current and state.current.name == name then
    local c = state.current
    if state.phase == "paused" then
      applyRowState(row, "paused")
      if (c.total or 0) > 0 then
        row.stateText:SetText(string.format("paused — %s / %s (%d%%)",
          fmtGroup(c.idx or 0), fmtGroup(c.total),
          math.floor(100 * (c.idx or 0) / math.max(c.total, 1))))
      else
        row.stateText:SetText("paused — parsing pending")
      end
    elseif state.phase == "errored" then
      applyRowState(row, "error")
      row.stateText:SetText("error")
    elseif (c.total or 0) <= 0 then
      applyRowState(row, "importing")
      row.stateText:SetText("parsing…")
    else
      applyRowState(row, "importing")
      local pct = math.floor(100 * (c.idx or 0) / math.max(c.total, 1))
      local eta = estimateCurrentEta(state)
      if eta and eta > 0 then
        row.stateText:SetText(string.format("%s / %s (%d%%) — ~%s left",
          fmtGroup(c.idx or 0), fmtGroup(c.total), pct, fmtDuration(eta)))
      else
        row.stateText:SetText(string.format("%s / %s (%d%%)",
          fmtGroup(c.idx or 0), fmtGroup(c.total), pct))
      end
    end
    setRowProgress(row, c.idx or 0, c.total or 0)
    return
  end

  -- Otherwise queued.
  applyRowState(row, "queued")
  row.stateText:SetText("queued")
  setRowProgress(row, 0, 0)
end

local function syncInputs(state)
  if not (state.config) then return end
  -- Suppress focus-lost commit while we set text programmatically.
  suppressInputCommit = true
  if not budgetEdit:HasFocus() then
    budgetEdit:SetText(tostring(state.config.budgetRows or 10000))
  end
  if not delayEdit:HasFocus() then
    delayEdit:SetText(string.format("%.1f", state.config.delaySec or 2.0))
  end
  suppressInputCommit = false
end

local function syncButtons(state)
  if state.phase == "running" then
    pauseBtn:Enable();  resumeBtn:Disable(); cancelBtn:Enable()
  elseif state.phase == "paused" then
    pauseBtn:Disable(); resumeBtn:Enable();  cancelBtn:Enable()
  elseif state.phase == "cancelled" or state.phase == "errored" then
    pauseBtn:Disable(); resumeBtn:Enable();  cancelBtn:Disable()
  else
    -- flushing, done, or any terminal/transient state — no controls.
    pauseBtn:Disable(); resumeBtn:Disable(); cancelBtn:Disable()
  end
end

local function syncTitle(state)
  if state.phase == "paused" then
    titleText:SetText("Importing from siblings — paused")
  elseif state.phase == "flushing" then
    titleText:SetText("Flushing archives…")
  elseif state.phase == "done" then
    titleText:SetText("Backfill complete")
  elseif state.phase == "cancelled" then
    titleText:SetText("Backfill stopped")
  elseif state.phase == "errored" then
    titleText:SetText("Backfill error")
  else
    titleText:SetText("Importing from siblings")
  end
end

local function syncFooter(state)
  local imported = (ns.Import and ns.Import.GetTotalImported and ns.Import:GetTotalImported()) or 0
  local sourcesTotal = #((state.config and state.config.sources) or {})
  local done = 0
  for _, r in ipairs(state.results or {}) do
    if not r.skippedSource then done = done + 1 end
  end
  if state.phase == "flushing" then
    footerText:SetText(string.format("Flushing %d / %d archives.",
      state.flushIdx or 0, state.flushTotal or 0))
  elseif state.phase == "done" then
    footerText:SetText(string.format("%s rows imported, %d archives written.",
      fmtGroup(imported), state.archivesWritten or 0))
  elseif state.phase == "errored" then
    footerText:SetText("Error: " .. tostring(state.lastError or "unknown"))
  elseif state.phase == "cancelled" then
    footerText:SetText("Stopped after " .. fmtGroup(imported) .. " rows — Resume to continue.")
  else
    footerText:SetText(string.format("%d / %d sources done · %s rows imported",
      done, sourcesTotal, fmtGroup(imported)))
  end
end

local function syncBadge(state)
  if not badge then return end
  local pct = 0
  local c = state.current
  if c and (c.total or 0) > 0 then
    pct = math.floor(100 * (c.idx or 0) / math.max(c.total, 1))
  elseif state.phase == "done" then
    pct = 100
  end
  if state.phase == "paused" then
    badge.pctText:SetText("||")
  elseif state.phase == "errored" then
    badge.pctText:SetText("!")
  else
    badge.pctText:SetText(tostring(pct) .. "%")
  end
end

-- Compare the controller's source list against rows[] keys; rebuild if changed.
local function sourcesChanged(state)
  local sources = (state.config and state.config.sources) or {}
  if #sources ~= #rowOrder then return true end
  for i, name in ipairs(sources) do
    if rowOrder[i] ~= name then return true end
  end
  return false
end

local function render()
  local state = (ns.Import and ns.Import.GetState and ns.Import:GetState()) or { phase = "idle" }
  if state.phase == "idle" then return end

  createFrame()
  createBadge()

  if sourcesChanged(state) then rebuildRows(state) end

  syncTitle(state)
  syncInputs(state)
  syncButtons(state)
  for _, name in ipairs(rowOrder) do updateRow(name, state) end
  syncFooter(state)
  syncBadge(state)

  -- Auto-fade on done; keep visible briefly so the player sees the result.
  if state.phase == "done" then
    if autoHideTimer then autoHideTimer.cancelled = true end
    autoHideTimer = { cancelled = false }
    local handle = autoHideTimer
    if C_Timer and C_Timer.After then
      C_Timer.After(6, function()
        if handle.cancelled then return end
        Control:Hide()
      end)
    end
  end
end

-- ============================================================================
-- Listener integration
-- ============================================================================

local function onImportUpdate()
  if not frame or not frame:IsShown() then
    if badge and badge:IsShown() then
      -- still update badge progress while minimised
      render()
      return
    end
    return
  end
  render()
end

-- ============================================================================
-- Public API
-- ============================================================================

function Control:Show()
  createFrame()
  createBadge()
  if ns.Import and ns.Import.RegisterListener then
    ns.Import:RegisterListener(listenerHandle, onImportUpdate)
  end
  local saved = ensureSavedPosition()
  if saved.mode == "minimised" then
    frame:Hide()
    applySavedPoint(badge, saved.minimised)
    badge:Show()
  else
    badge:Hide()
    applySavedPoint(frame, saved.expanded)
    frame:Show()
  end
  render()
end

function Control:Hide()
  if frame then frame:Hide() end
  if badge then badge:Hide() end
  if ns.Import and ns.Import.UnregisterListener then
    ns.Import:UnregisterListener(listenerHandle)
  end
end

function Control:Minimise()
  if not frame then return end
  local saved = ensureSavedPosition()
  saved.mode = "minimised"
  createBadge()
  frame:Hide()
  applySavedPoint(badge, saved.minimised)
  badge:Show()
  render()
end

function Control:Restore()
  if not frame then return end
  local saved = ensureSavedPosition()
  saved.mode = "expanded"
  if badge then badge:Hide() end
  applySavedPoint(frame, saved.expanded)
  frame:Show()
  render()
end

function Control:IsShown()
  return (frame and frame:IsShown()) or (badge and badge:IsShown()) or false
end
