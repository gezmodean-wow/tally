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
      if err and ns.Output then ns.Output:Error(tostring(err)) end
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

-- Themed button via Cogworks. The library returns a button with hover/press
-- visuals matching the rest of the suite chrome; falls back to WoW's
-- UIPanelButtonTemplate when Cogworks isn't loaded.
local function makeButton(parent, label, w, onClick)
  local cw = getCogworks()
  if cw and cw.CreateButton then
    return cw:CreateButton(parent, label, w or 120, 22, onClick)
  end
  local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  btn:SetSize(w or 120, 22)
  btn:SetText(label)
  btn:SetScript("OnClick", onClick)
  return btn
end

function ns.UI.CreateSettingsPage(parent)
  -- Outer wrapper returned to MainFrame. Filled by the scroll frame so
  -- our content can grow taller than the main-frame body.
  local outer = CreateFrame("Frame", nil, parent)

  local scrollFrame = CreateFrame("ScrollFrame", nil, outer)
  scrollFrame:SetPoint("TOPLEFT", outer, "TOPLEFT", 0, 0)
  scrollFrame:SetPoint("BOTTOMRIGHT", outer, "BOTTOMRIGHT", -10, 0)
  scrollFrame:EnableMouseWheel(true)
  scrollFrame:SetScript("OnMouseWheel", function(self, delta)
    local cur = self:GetVerticalScroll()
    local maxScroll = self:GetVerticalScrollRange()
    local step = 30
    self:SetVerticalScroll(math.max(0, math.min(cur - delta * step, maxScroll)))
  end)

  -- The actual content host. All section anchors below point at `page`,
  -- which is now the scroll-child — sizing it tall enough to fit every
  -- section is what enables scrolling. Width tracks the scrollFrame.
  local page = CreateFrame("Frame", nil, scrollFrame)
  page:SetSize(540, 720)  -- height is a generous initial estimate; we
                          -- recompute precisely at the bottom of build
                          -- once every section's BOTTOM anchor exists.
  scrollFrame:SetScrollChild(page)
  scrollFrame:SetScript("OnSizeChanged", function(self, w, _)
    page:SetWidth(w)
  end)

  -- Thin themed scrollbar (mirrors cw:CreateScrollTable's track/thumb
  -- styling so this page reads as the same family).
  local track = CreateFrame("Frame", nil, outer)
  track:SetWidth(6)
  track:SetPoint("TOPLEFT", scrollFrame, "TOPRIGHT", 2, 0)
  track:SetPoint("BOTTOMLEFT", scrollFrame, "BOTTOMRIGHT", 2, 0)
  local trackBg = track:CreateTexture(nil, "BACKGROUND")
  trackBg:SetAllPoints()
  trackBg:SetColorTexture(themeColor("border", { 0.30, 0.30, 0.40, 0.15 }))
  local thumb = track:CreateTexture(nil, "ARTWORK")
  thumb:SetWidth(6)
  thumb:SetColorTexture(themeColor("brass", { 0.83, 0.63, 0.09, 0.5 }))

  local function updateThumb()
    local maxScroll = scrollFrame:GetVerticalScrollRange()
    local trackH = track:GetHeight()
    if maxScroll <= 0 or trackH <= 0 then thumb:Hide(); return end
    thumb:Show()
    local viewH = scrollFrame:GetHeight()
    local contentH = viewH + maxScroll
    local thumbH = math.max(20, trackH * (viewH / contentH))
    thumb:SetHeight(thumbH)
    local pos = (scrollFrame:GetVerticalScroll() / maxScroll) * (trackH - thumbH)
    thumb:ClearAllPoints()
    thumb:SetPoint("TOP", track, "TOP", 0, -pos)
  end
  scrollFrame:HookScript("OnVerticalScroll", updateThumb)
  scrollFrame:HookScript("OnSizeChanged", updateThumb)
  scrollFrame:HookScript("OnScrollRangeChanged", updateThumb)

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
      if err and ns.Output then ns.Output:Error(tostring(err)) end
      loadStrategy()
    elseif ns.Output then
      ns.Output:Success("Price strategy set to '" .. expr .. "'.")
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
    if ok and ns.Output then
      ns.Output:Success(string.format("Snapshot recorded — %d priced items, %d inventory items.",
        info.pricedItems, info.inventoryItems))
    elseif not ok and ns.Output then
      ns.Output:Error(tostring(info))
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
        if ns.Output then ns.Output:Success("All history cleared.") end
        if page.Refresh then page:Refresh() end
      end,
    }
    StaticPopup_Show("TALLY_CLEAR_HISTORY")
  end)
  clearBtn:SetPoint("LEFT", snapBtn, "RIGHT", 8, 0)

  -- ============================================================================
  -- SECTION 4: Data sources — registered ledger adapters with import controls
  -- ============================================================================

  local sourcesHdr = makeSectionHeader(page, actionRow, "BOTTOMLEFT", 18, "DATA SOURCES")

  -- TLY-31 Phase B: Tally now treats sibling adapters as backfill sources,
  -- not periodic auto-importers. The Import now button stays per source
  -- for manual top-up; the recurring 5-min ticker is gone. This note
  -- frames the section so users don't expect their TSM rows to update
  -- live without clicking through.
  local sourcesNote = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  sourcesNote:SetPoint("TOPLEFT", sourcesHdr, "BOTTOMLEFT", 0, -4)
  sourcesNote:SetPoint("RIGHT", page, "RIGHT", -4, 0)
  sourcesNote:SetJustifyH("LEFT")
  sourcesNote:SetSpacing(2)
  sourcesNote:SetText("Sibling adapters (TSM, FlipQueue, Journalator) are backfill-only — "
    .. "imported once on first setup and on the buttons below. Tally's native source "
    .. "captures new events live (mailbox / vendor / repair / posting) — no manual refresh.")

  local sourcesContainer = CreateFrame("Frame", nil, page)
  sourcesContainer:SetPoint("TOPLEFT", sourcesNote, "BOTTOMLEFT", 0, -8)
  sourcesContainer:SetPoint("RIGHT", page, "RIGHT", 0, 0)
  sourcesContainer:SetHeight(1) -- height grows with rows

  local sourceRows = {}

  local function getSourceRow(i)
    local row = sourceRows[i]
    if not row then
      row = CreateFrame("Frame", nil, sourcesContainer)
      row:SetHeight(22)
      row:SetPoint("LEFT", sourcesContainer, "LEFT", 0, 0)
      row:SetPoint("RIGHT", sourcesContainer, "RIGHT", 0, 0)

      row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.label:SetPoint("LEFT", row, "LEFT", 0, 0)
      row.label:SetWidth(160)
      row.label:SetJustifyH("LEFT")

      row.status = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      row.status:SetPoint("LEFT", row.label, "RIGHT", 8, 0)
      row.status:SetWidth(120)
      row.status:SetJustifyH("LEFT")

      row.count = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      row.count:SetPoint("LEFT", row.status, "RIGHT", 8, 0)
      row.count:SetWidth(120)
      row.count:SetJustifyH("LEFT")

      row.btn = makeButton(row, "Import now", 100, function() end)
      row.btn:SetPoint("RIGHT", row, "RIGHT", 0, 0)

      sourceRows[i] = row
    end
    return row
  end

  local function loadSources()
    if not (ns.Ledger and ns.Ledger.GetSources) then return end
    local list = ns.Ledger:GetSources()
    for i, s in ipairs(list) do
      local row = getSourceRow(i)
      row:SetPoint("TOPLEFT", sourcesContainer, "TOPLEFT", 0, -(i - 1) * 24)
      row.label:SetText(s.label or s.name)

      local available = ns.Ledger:IsSourceAvailable(s.name)
      if available then
        row.status:SetText("|cff7fffaeAvailable|r")
      else
        row.status:SetText("|cff888888Not detected|r")
      end

      local count = #(ns.Ledger:Query({ source = s.name }))
      row.count:SetText(string.format("%d entries", count))

      row.btn:SetEnabled(available)
      row.btn:SetScript("OnClick", function()
        local inserted, skipped, err = ns.Ledger:ImportFromSource(s.name)
        if err and ns.Output then
          ns.Output:Error("Import failed for " .. s.name .. " — " .. tostring(err))
        elseif ns.Output then
          ns.Output:Success(string.format("Imported %d new entries from %s (%d skipped as duplicates).",
            inserted or 0, s.name, skipped or 0))
        end
        loadSources()
      end)
      row:Show()
    end
    for i = #list + 1, #sourceRows do sourceRows[i]:Hide() end
    sourcesContainer:SetHeight(math.max(1, #list * 24))
  end
  refreshFns[#refreshFns + 1] = loadSources

  -- ============================================================================
  -- SECTION 5: Setup + advanced views
  -- ============================================================================

  local setupHdr = makeSectionHeader(page, sourcesContainer, "BOTTOMLEFT", 18, "SETUP + ADVANCED")

  local setupRow = CreateFrame("Frame", nil, page)
  setupRow:SetPoint("TOPLEFT", setupHdr, "BOTTOMLEFT", 0, -10)
  setupRow:SetPoint("RIGHT", page, "RIGHT", 0, 0)
  setupRow:SetHeight(24)

  local rerunBtn = makeButton(setupRow, "Re-run setup wizard", 180, function()
    if ns.UI and ns.UI.ShowSetupWizard then
      ns.UI.ShowSetupWizard()
    elseif ns.Output then
      ns.Output:Error("Setup wizard unavailable.")
    end
  end)
  rerunBtn:SetPoint("LEFT", setupRow, "LEFT", 0, 0)

  local rerunNote = setupRow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  rerunNote:SetPoint("LEFT", rerunBtn, "RIGHT", 12, 0)
  rerunNote:SetPoint("RIGHT", setupRow, "RIGHT", 0, 0)
  rerunNote:SetJustifyH("LEFT")
  rerunNote:SetText("Walk through source detection, strategy, history config, and chunked backfill again.")

  -- Compare-tab toggle
  local compareRow = CreateFrame("Frame", nil, page)
  compareRow:SetPoint("TOPLEFT", setupRow, "BOTTOMLEFT", 0, -6)
  compareRow:SetPoint("RIGHT", page, "RIGHT", 0, 0)
  compareRow:SetHeight(22)

  local compareCB = CreateFrame("CheckButton", nil, compareRow, "UICheckButtonTemplate")
  compareCB:SetSize(20, 20)
  compareCB:SetPoint("LEFT", compareRow, "LEFT", 0, 0)
  TallyDB.ui = TallyDB.ui or {}
  compareCB:SetChecked(TallyDB.ui.showCompareTab and true or false)

  local compareLabel = compareRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  compareLabel:SetPoint("LEFT", compareCB, "RIGHT", 4, 0)
  compareLabel:SetText("Show ledger comparison tab")

  local compareNote = compareRow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  compareNote:SetPoint("LEFT", compareLabel, "RIGHT", 12, 0)
  compareNote:SetPoint("RIGHT", compareRow, "RIGHT", 0, 0)
  compareNote:SetJustifyH("LEFT")
  compareNote:SetText("Debug-oriented side-by-side diff between two ledger sources. Reload required for tab to appear/disappear.")

  compareCB:SetScript("OnClick", function(self)
    TallyDB.ui = TallyDB.ui or {}
    TallyDB.ui.showCompareTab = self:GetChecked() and true or nil
    -- Live-register the page on enable so users don't strictly need a reload
    -- to use it — only to remove the tab visually.
    if TallyDB.ui.showCompareTab and ns.UI and ns.UI.MainFrame and ns.UI.CreateCompareLedgersPage
       and ns.UI.MainFrame.RegisterPage and not ns.UI.MainFrame:GetPage("Compare") then
      ns.UI.MainFrame:RegisterPage("Compare", ns.UI.CreateCompareLedgersPage)
    end
  end)

  -- ============================================================================
  -- SECTION 6: Maintenance — seal old ledger rows into archives
  -- ============================================================================

  local maintHdr = makeSectionHeader(page, compareRow, "BOTTOMLEFT", 18, "MAINTENANCE")

  local sealRow = CreateFrame("Frame", nil, page)
  sealRow:SetPoint("TOPLEFT", maintHdr, "BOTTOMLEFT", 0, -10)
  sealRow:SetPoint("RIGHT", page, "RIGHT", 0, 0)
  sealRow:SetHeight(24)

  local sealStatus = sealRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")

  local sealBtn = makeButton(sealRow, "Seal old data into archives", 220, function()
    if not (ns.Ledger and ns.Ledger.Seal) then
      if ns.Output then ns.Output:Error("Seal unavailable.") end
      return
    end
    if ns.Ledger:IsMigrationRunning() then
      if ns.Output then ns.Output:Warn("Migration in progress — wait for it to finish before sealing.") end
      return
    end
    if ns.Ledger:IsSealRunning() then
      if ns.Output then ns.Output:Warn("Seal already running.") end
      return
    end

    local preview = ns.Ledger:SealPreview()
    if preview.sealCount == 0 then
      if ns.Output then ns.Output:Info("Nothing to seal — active set is within the soft cap.") end
      return
    end

    StaticPopupDialogs["TALLY_SEAL_CONFIRM"] = StaticPopupDialogs["TALLY_SEAL_CONFIRM"] or {
      text = "Seal %d ledger rows older than %s into monthly archives?\n\nKeeps the %d newest rows in the active set. Archives are read-only and lazy-loaded by Compare and Lifecycle when you ask for full-history scope. Logout-time saves stay fast after.",
      button1 = ACCEPT or "Accept",
      button2 = CANCEL or "Cancel",
      timeout = 0,
      whileDead = true,
      hideOnEscape = true,
    }
    StaticPopupDialogs["TALLY_SEAL_CONFIRM"].OnAccept = function()
      if ns.Output then
        ns.Output:Info(string.format("Sealing %d rows into archives…", preview.sealCount))
      end
      ns.Ledger:Seal({
        onProgress = function(phase, idx, total, key)
          if phase == "flush" and ns.Output then
            ns.Output:Debug(string.format("seal flush archive %s (%d / %d)", key or "?", idx, total))
          end
        end,
        onComplete = function(sealed, archivesWritten)
          if ns.Output then
            ns.Output:Success(string.format(
              "Sealed %d rows into %d archives. Logout will save the slimmed active set.",
              sealed, archivesWritten))
          end
          if outer.Refresh then pcall(outer.Refresh, outer) end
          if ns.UI and ns.UI.MainFrame and ns.UI.MainFrame.UpdateHeaderNudge then
            pcall(ns.UI.MainFrame.UpdateHeaderNudge, ns.UI.MainFrame)
          end
        end,
      })
    end
    StaticPopup_Show("TALLY_SEAL_CONFIRM",
      preview.sealCount,
      date("%Y-%m-%d", preview.cutTime or time()),
      preview.keepCount)
  end)
  sealBtn:SetPoint("LEFT", sealRow, "LEFT", 0, 0)

  sealStatus:SetPoint("LEFT", sealBtn, "RIGHT", 12, 0)
  sealStatus:SetPoint("RIGHT", sealRow, "RIGHT", 0, 0)
  sealStatus:SetJustifyH("LEFT")
  sealStatus:SetText("")

  refreshFns[#refreshFns + 1] = function()
    if not (ns.Ledger and ns.Ledger.SealPreview) then return end
    local p = ns.Ledger:SealPreview()
    if p.sealCount > 0 then
      sealStatus:SetText(string.format("Active: %d rows — sealing would archive %d (older than %s).",
        p.activeCount, p.sealCount, date("%Y-%m-%d", p.cutTime or time())))
    else
      sealStatus:SetText(string.format("Active: %d rows — within soft cap, no seal needed.", p.activeCount))
    end
  end

  -- ============================================================================
  -- SECTION 7: Danger zone — full data reset (testing aid + recovery path)
  -- ============================================================================

  local dangerHdr = makeSectionHeader(page, sealRow, "BOTTOMLEFT", 18, "DANGER ZONE")

  local resetRow = CreateFrame("Frame", nil, page)
  resetRow:SetPoint("TOPLEFT", dangerHdr, "BOTTOMLEFT", 0, -10)
  resetRow:SetPoint("RIGHT", page, "RIGHT", 0, 0)
  resetRow:SetHeight(24)

  local resetBtn = makeButton(resetRow, "Reset all Tally data", 200, function()
    StaticPopupDialogs["TALLY_RESET_DATA"] = StaticPopupDialogs["TALLY_RESET_DATA"] or {
      text = "Wipe Tally's ledger, history, inventory rollup, and setup state?\n\nConfig (strategy, cadence, minimap, UI position) is preserved. The setup wizard will reopen so you can re-pick sources, strategy, and pace; the chunked backfill kicks off when you finish the wizard.\n\nThis cannot be undone.",
      button1 = ACCEPT or "Accept",
      button2 = CANCEL or "Cancel",
      timeout = 0,
      whileDead = true,
      hideOnEscape = true,
      OnAccept = function()
        if ns.Reset then ns.Reset() end
        -- Don't Refresh page right after — Reset hides the main frame
        -- and shows the wizard. The Settings panel will pick up fresh
        -- state next time it's opened.
      end,
    }
    StaticPopup_Show("TALLY_RESET_DATA")
  end)
  resetBtn:SetPoint("LEFT", resetRow, "LEFT", 0, 0)

  local resetNote = resetRow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  resetNote:SetPoint("LEFT", resetBtn, "RIGHT", 12, 0)
  resetNote:SetPoint("RIGHT", resetRow, "RIGHT", 0, 0)
  resetNote:SetJustifyH("LEFT")
  resetNote:SetText("Wipes data + reopens setup wizard. Config (strategy, cadence) preserved.")

  -- Size the scroll-child to fit every section. Without this, the scroll
  -- frame thinks the content is exactly its own viewport height and
  -- nothing scrolls. We use a generous fixed height that covers the
  -- max likely source-row count; the bottom dead-space is harmless.
  page:SetHeight(720)

  -- Public refresh ------------------------------------------------------------

  function page:Refresh()
    for _, fn in ipairs(refreshFns) do
      pcall(fn)
    end
    -- Re-tally page height now that loadSources may have grown the
    -- DATA SOURCES container, so the bottom DANGER ZONE is reachable.
    local dynamicH = 720
    if sourcesContainer and sourcesContainer.GetHeight then
      dynamicH = 720 + math.max(0, sourcesContainer:GetHeight() - 24)
    end
    page:SetHeight(dynamicH)
  end

  function outer:Refresh() page:Refresh() end

  page:Refresh()
  return outer
end
