-- Tally — UI/SettingsPage.lua
--
-- Third tab in the main frame. Surfaces history configuration knobs
-- (cadence / retention / rollup), the current pricing strategy with a
-- setter, snapshot status (last + oldest, per strategy), and maintenance
-- actions (force snapshot, clear all history). All values apply on Enter
-- or focus-loss; invalid values revert with a flash.
--
-- Public surface:
--   page = ns.UI.CreateSettingsPage(parent)

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

local function describeAge(seconds)
  if not seconds or seconds <= 0 then return "—" end
  local d = math.floor(seconds / 86400)
  if d > 0 then return d .. "d" end
  local h = math.floor(seconds / 3600)
  if h > 0 then return h .. "h" end
  local m = math.floor(seconds / 60)
  if m > 0 then return m .. "m" end
  return seconds .. "s"
end

-- Section header — bold uppercase label with a brass underline.
-- Anchors to (anchorFrame, anchorPoint) with a vertical `gap` (positive = below).
local function makeSectionHeader(parent, anchorFrame, anchorPoint, gap, text)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  fs:SetPoint("TOPLEFT", anchorFrame, anchorPoint, 0, -gap)
  fs:SetText(text)
  fs:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))
  local rule = parent:CreateTexture(nil, "ARTWORK")
  rule:SetPoint("TOPLEFT", fs, "BOTTOMLEFT", 0, -2)
  rule:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
  rule:SetHeight(1)
  rule:SetColorTexture(themeColor("border", { 0.30, 0.30, 0.40, 0.6 }))
  return fs, rule
end

-- Numeric input with label + suffix. value applies on Enter/focus-loss
-- via setter(numericValue). On invalid input the field reverts via getter.
local function makeNumericField(parent, opts)
  local row = CreateFrame("Frame", nil, parent)
  row:SetSize(opts.rowWidth or 360, 24)

  local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  label:SetPoint("LEFT", row, "LEFT", 0, 0)
  label:SetWidth(opts.labelWidth or 140)
  label:SetJustifyH("LEFT")
  label:SetText(opts.label)

  local input = CreateFrame("EditBox", nil, row, "BackdropTemplate")
  input:SetPoint("LEFT", label, "RIGHT", 6, 0)
  input:SetSize(opts.inputWidth or 60, 22)
  input:SetAutoFocus(false)
  input:SetFontObject("GameFontHighlight")
  input:SetTextInsets(6, 6, 0, 0)
  input:SetNumeric(false) -- accept fractional via tonumber
  input:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  input:SetBackdropColor(themeColor("bgDark", { 0.04, 0.04, 0.07, 1 }))
  input:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))

  local suffix = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  suffix:SetPoint("LEFT", input, "RIGHT", 6, 0)
  suffix:SetText(opts.suffix or "")

  local note = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("LEFT", suffix, "RIGHT", 14, 0)
  note:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  note:SetJustifyH("LEFT")
  note:SetText(opts.note or "")

  local function load()
    input:SetText(tostring(opts.getter() or ""))
  end

  local function flashError()
    input:SetBackdropBorderColor(themeColor("error", { 1, 0.25, 0.25, 1 }))
    C_Timer.After(0.6, function()
      input:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))
    end)
  end

  local function commit()
    local raw = input:GetText()
    local n = tonumber(raw)
    if n == nil and not opts.allowZero then
      flashError(); load(); return
    end
    if n and n < 0 then
      flashError(); load(); return
    end
    if not opts.allowZero and (n == 0 or n == nil) then
      flashError(); load(); return
    end
    local ok, err = opts.setter(n or 0)
    if not ok then
      flashError(); load()
      if err then print("|cffff4040Tally:|r " .. err) end
    else
      load()
    end
  end

  input:SetScript("OnEnterPressed", function(self) commit(); self:ClearFocus() end)
  input:SetScript("OnEscapePressed", function(self) load(); self:ClearFocus() end)
  input:SetScript("OnEditFocusLost", function() commit() end)

  load()
  return row, load
end

local function makeButton(parent, label, w, onClick)
  local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  btn:SetSize(w or 120, 22)
  btn:SetText(label)
  btn:SetScript("OnClick", onClick)
  return btn
end

function ns.UI.CreateSettingsPage(parent)
  local page = CreateFrame("Frame", nil, parent)

  local refreshFns = {}

  -- ============================================================================
  -- SECTION 1: History cadence
  -- ============================================================================

  local hCadenceHdr = makeSectionHeader(page, page, "TOPLEFT", 2, "HISTORY CADENCE")

  local intervalRow, loadInterval = makeNumericField(page, {
    label = "Interval",
    suffix = "hours",
    note = "0 disables auto-snapshots; default 6",
    allowZero = true,
    getter = function()
      if not ns.History then return 6 end
      return (ns.History:GetConfig().minIntervalSec or 0) / 3600
    end,
    setter = function(hours)
      if not ns.History then return false, "history unavailable" end
      return ns.History:SetInterval(hours * 3600)
    end,
  })
  intervalRow:SetPoint("TOPLEFT", hCadenceHdr, "BOTTOMLEFT", 0, -10)
  refreshFns[#refreshFns + 1] = loadInterval

  local retentionRow, loadRetention = makeNumericField(page, {
    label = "Retention",
    suffix = "days",
    note = "snapshots older than this are pruned; default 365",
    getter = function()
      if not ns.History then return 365 end
      return math.floor((ns.History:GetConfig().retentionSec or 0) / 86400)
    end,
    setter = function(days)
      if not ns.History then return false, "history unavailable" end
      return ns.History:SetRetention(days * 86400)
    end,
  })
  retentionRow:SetPoint("TOPLEFT", intervalRow, "BOTTOMLEFT", 0, -4)
  refreshFns[#refreshFns + 1] = loadRetention

  local rollupRow, loadRollup = makeNumericField(page, {
    label = "Daily-rollup after",
    suffix = "days",
    note = "snapshots older than this are kept at one per day; default 30",
    getter = function()
      if not ns.History then return 30 end
      return math.floor((ns.History:GetConfig().rollupAfterSec or 0) / 86400)
    end,
    setter = function(days)
      if not ns.History then return false, "history unavailable" end
      return ns.History:SetRollupThreshold(days * 86400)
    end,
  })
  rollupRow:SetPoint("TOPLEFT", retentionRow, "BOTTOMLEFT", 0, -4)
  refreshFns[#refreshFns + 1] = loadRollup

  -- ============================================================================
  -- SECTION 2: Pricing strategy
  -- ============================================================================

  local stratHdr = makeSectionHeader(page, rollupRow, "BOTTOMLEFT", 18, "PRICING STRATEGY")

  local stratRow = CreateFrame("Frame", nil, page)
  stratRow:SetPoint("TOPLEFT", stratHdr, "BOTTOMLEFT", 0, -10)
  stratRow:SetSize(540, 24)

  local stratLabel = stratRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  stratLabel:SetPoint("LEFT", stratRow, "LEFT", 0, 0)
  stratLabel:SetWidth(140)
  stratLabel:SetJustifyH("LEFT")
  stratLabel:SetText("TSM expression")

  local stratInput = CreateFrame("EditBox", nil, stratRow, "BackdropTemplate")
  stratInput:SetPoint("LEFT", stratLabel, "RIGHT", 6, 0)
  stratInput:SetSize(260, 22)
  stratInput:SetAutoFocus(false)
  stratInput:SetFontObject("GameFontHighlight")
  stratInput:SetTextInsets(6, 6, 0, 0)
  stratInput:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  stratInput:SetBackdropColor(themeColor("bgDark", { 0.04, 0.04, 0.07, 1 }))
  stratInput:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))

  local function loadStrategy()
    if ns.NetWorth then
      stratInput:SetText(ns.NetWorth:GetStrategy() or "")
    end
  end
  refreshFns[#refreshFns + 1] = loadStrategy

  local function commitStrategy()
    if not ns.NetWorth then return end
    local expr = stratInput:GetText()
    if not expr or expr == "" then loadStrategy(); return end
    local ok, err = ns.NetWorth:SetStrategy(expr)
    if not ok then
      stratInput:SetBackdropBorderColor(themeColor("error", { 1, 0.25, 0.25, 1 }))
      C_Timer.After(0.6, function()
        stratInput:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))
      end)
      if err then print("|cffff4040Tally:|r " .. err) end
      loadStrategy()
    else
      print("|cff7fbfffTally:|r price strategy set to '" .. expr .. "'.")
    end
  end
  stratInput:SetScript("OnEnterPressed", function(self) commitStrategy(); self:ClearFocus() end)
  stratInput:SetScript("OnEscapePressed", function(self) loadStrategy(); self:ClearFocus() end)
  stratInput:SetScript("OnEditFocusLost", function() commitStrategy() end)

  local stratNote = stratRow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  stratNote:SetPoint("LEFT", stratInput, "RIGHT", 8, 0)
  stratNote:SetPoint("RIGHT", stratRow, "RIGHT", 0, 0)
  stratNote:SetJustifyH("LEFT")
  stratNote:SetText("any TSM-valid expression; e.g. DBMarket, DBRegionMarketAvg")

  loadStrategy()

  -- ============================================================================
  -- SECTION 3: Snapshots & maintenance
  -- ============================================================================

  local snapHdr = makeSectionHeader(page, stratRow, "BOTTOMLEFT", 18, "SNAPSHOTS")

  local snapStatus = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  snapStatus:SetPoint("TOPLEFT", snapHdr, "BOTTOMLEFT", 0, -10)
  snapStatus:SetPoint("RIGHT", page, "RIGHT", 0, 0)
  snapStatus:SetJustifyH("LEFT")
  snapStatus:SetSpacing(2)

  local function loadSnapStatus()
    if not (ns.History and ns.History.GetSummary) then
      snapStatus:SetText("(history unavailable)")
      return
    end
    local summary = ns.History:GetSummary()
    local now = time()
    local lines = {}
    if #summary.pricing == 0 then
      lines[#lines + 1] = "Pricing: no snapshots yet"
    else
      for _, row in ipairs(summary.pricing) do
        local ageLast = row.lastSnapshotAt and (now - row.lastSnapshotAt) or nil
        local span = (row.lastSnapshotAt and row.oldestAt) and (row.lastSnapshotAt - row.oldestAt) or 0
        lines[#lines + 1] = string.format("Pricing [%s]: %d snapshots, last %s ago, spanning %s",
          row.strategy, row.snapshotCount, describeAge(ageLast), describeAge(span))
      end
    end
    if summary.inventory.snapshotCount == 0 then
      lines[#lines + 1] = "Inventory: no snapshots yet"
    else
      local inv = summary.inventory
      local ageLast = inv.lastSnapshotAt and (now - inv.lastSnapshotAt) or nil
      local span = (inv.lastSnapshotAt and inv.oldestAt) and (inv.lastSnapshotAt - inv.oldestAt) or 0
      lines[#lines + 1] = string.format("Inventory: %d snapshots, last %s ago, spanning %s",
        inv.snapshotCount, describeAge(ageLast), describeAge(span))
    end
    snapStatus:SetText(table.concat(lines, "\n"))
  end
  refreshFns[#refreshFns + 1] = loadSnapStatus

  local actionRow = CreateFrame("Frame", nil, page)
  actionRow:SetPoint("TOPLEFT", snapStatus, "BOTTOMLEFT", 0, -10)
  actionRow:SetSize(540, 24)

  local snapBtn = makeButton(actionRow, "Take snapshot now", 160, function()
    if not ns.History then return end
    local ok, info = ns.History:Snapshot({ force = true })
    if ok then
      print(string.format("|cff7fbfffTally:|r snapshot recorded — %d priced items, %d inventory items.",
        info.pricedItems, info.inventoryItems))
    else
      print("|cffff4040Tally:|r " .. tostring(info))
    end
    loadSnapStatus()
  end)
  snapBtn:SetPoint("LEFT", actionRow, "LEFT", 0, 0)

  local clearBtn = makeButton(actionRow, "Clear all history", 160, function()
    StaticPopupDialogs["TALLY_CLEAR_HISTORY"] = StaticPopupDialogs["TALLY_CLEAR_HISTORY"] or {
      text = "Wipe all Tally pricing + inventory history?\n\nThis cannot be undone. Tally will start collecting fresh snapshots from your next login.",
      button1 = ACCEPT or "Accept",
      button2 = CANCEL or "Cancel",
      timeout = 0,
      whileDead = true,
      hideOnEscape = true,
      OnAccept = function()
        if ns.History then ns.History:Clear() end
        print("|cff7fbfffTally:|r all history cleared.")
        if page.Refresh then page:Refresh() end
      end,
    }
    StaticPopup_Show("TALLY_CLEAR_HISTORY")
  end)
  clearBtn:SetPoint("LEFT", snapBtn, "RIGHT", 8, 0)

  -- Public refresh ------------------------------------------------------------

  function page:Refresh()
    for _, fn in ipairs(refreshFns) do
      pcall(fn)
    end
  end

  page:Refresh()
  return page
end
