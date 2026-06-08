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
  -- SECTION 1: Net-worth snapshots
  -- ============================================================================
  --
  -- TLY-81: the snapshot cadence is fixed (one per calendar day) — there
  -- is no interval or daily-rollup to configure any more, only how long
  -- the bounded time series is kept.

  local hCadenceHdr = makeSectionHeader(page, page, "TOPLEFT", 2, "NET-WORTH SNAPSHOTS")

  local retentionRow, loadRetention = makeNumericField(page, {
    label = "Retention",
    suffix = "days",
    note = "net-worth snapshots older than this are pruned; default 180",
    getter = function()
      if not (ns.Spine and ns.Spine.NetWorthStore) then return 180 end
      return ns.Spine.NetWorthStore:GetConfig().retentionDays or 180
    end,
    setter = function(days)
      if not (ns.Spine and ns.Spine.NetWorthStore) then
        return false, "snapshot store unavailable"
      end
      return ns.Spine.NetWorthStore:SetRetentionDays(days)
    end,
  })
  retentionRow:SetPoint("TOPLEFT", hCadenceHdr, "BOTTOMLEFT", 0, -10)
  refreshFns[#refreshFns + 1] = loadRetention

  -- ============================================================================
  -- SECTION 2: Pricing strategy
  -- ============================================================================

  local stratHdr = makeSectionHeader(page, retentionRow, "BOTTOMLEFT", 18, "PRICING STRATEGY")

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
    if not (ns.Spine and ns.Spine.NetWorthStore) then
      snapStatus:SetText("(snapshot store unavailable)")
      return
    end
    local sum = ns.Spine.NetWorthStore:GetSummary()
    if (sum.snapshotCount or 0) == 0 then
      snapStatus:SetText("Net-worth snapshots: none yet")
      return
    end
    local now = time()
    local ageLast = sum.lastSnapshotAt and (now - sum.lastSnapshotAt) or nil
    local span = (sum.lastSnapshotAt and sum.oldestAt)
      and (sum.lastSnapshotAt - sum.oldestAt) or 0
    snapStatus:SetText(string.format(
      "Net-worth snapshots: %d, last %s ago, spanning %s",
      sum.snapshotCount, describeAge(ageLast), describeAge(span)))
  end
  refreshFns[#refreshFns + 1] = loadSnapStatus

  local actionRow = CreateFrame("Frame", nil, page)
  actionRow:SetPoint("TOPLEFT", snapStatus, "BOTTOMLEFT", 0, -10)
  actionRow:SetSize(540, 24)

  local snapBtn = makeButton(actionRow, "Take snapshot now", 160, function()
    if not (ns.Spine and ns.Spine.NetWorthStore) then return end
    local ok, info = ns.Spine.NetWorthStore:MaybeSnapshot({ force = true })
    if ok and ns.Output then
      ns.Output:Success("Net-worth snapshot recorded — "
        .. ns.NetWorth.FormatGold(info.total) .. ".")
    elseif not ok and ns.Output then
      ns.Output:Error(tostring(info))
    end
    loadSnapStatus()
  end)
  snapBtn:SetPoint("LEFT", actionRow, "LEFT", 0, 0)

  local clearBtn = makeButton(actionRow, "Clear all snapshots", 160, function()
    StaticPopupDialogs["TALLY_CLEAR_HISTORY"] = StaticPopupDialogs["TALLY_CLEAR_HISTORY"] or {
      text = "Wipe all Tally net-worth snapshots?\n\nThis cannot be undone. Tally will start collecting fresh snapshots from your next login.",
      button1 = ACCEPT or "Accept",
      button2 = CANCEL or "Cancel",
      timeout = 0,
      whileDead = true,
      hideOnEscape = true,
      OnAccept = function()
        if ns.Spine and ns.Spine.NetWorthStore then ns.Spine.NetWorthStore:Clear() end
        if ns.Output then ns.Output:Success("Net-worth snapshots cleared.") end
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

  -- TLY-78: the projection-layer redesign parses sibling sources into the
  -- session spine cache on demand; Tally stores no ledger of its own. The
  -- per-source "Re-parse" button discards the cache and re-reads sources.
  local sourcesNote = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  sourcesNote:SetPoint("TOPLEFT", sourcesHdr, "BOTTOMLEFT", 0, -4)
  sourcesNote:SetPoint("RIGHT", page, "RIGHT", -4, 0)
  sourcesNote:SetJustifyH("LEFT")
  sourcesNote:SetSpacing(2)
  sourcesNote:SetText("Tally reads your ledger from sibling addons (TSM, FlipQueue, Journalator) — "
    .. "it stores no transactions of its own. Sources are parsed into the session cache "
    .. "the first time you open a detailed view; Re-parse re-reads them after a sibling updates.")

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

      row.btn = makeButton(row, "Re-parse", 100, function() end)
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

      -- The projection layer parses sibling sources into the session
      -- spine cache rather than importing into a stored ledger. "Re-parse"
      -- discards the cache and re-reads all sources; the per-source entry
      -- count above reflects the freshly recomputed unified ledger.
      row.btn:SetEnabled(available)
      row.btn:SetScript("OnClick", function()
        local PC = ns.Spine and ns.Spine.ParseCache
        if PC and PC.Refresh then
          if ns.Output then ns.Output:Info("Re-parsing sibling sources…") end
          PC:Refresh()
        elseif ns.Output then
          ns.Output:Error("Data spine unavailable.")
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
  rerunNote:SetText("Walk through source detection and strategy again.")

  -- Data-spine-tab toggle (TLY-77 projection-layer redesign)
  local spineRow = CreateFrame("Frame", nil, page)
  spineRow:SetPoint("TOPLEFT", setupRow, "BOTTOMLEFT", 0, -6)
  spineRow:SetPoint("RIGHT", page, "RIGHT", 0, 0)
  spineRow:SetHeight(22)

  local spineCB = CreateFrame("CheckButton", nil, spineRow, "UICheckButtonTemplate")
  spineCB:SetSize(20, 20)
  spineCB:SetPoint("LEFT", spineRow, "LEFT", 0, 0)
  TallyDB.ui = TallyDB.ui or {}
  spineCB:SetChecked(TallyDB.ui.showSpineTab and true or false)

  local spineLabel = spineRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  spineLabel:SetPoint("LEFT", spineCB, "RIGHT", 4, 0)
  spineLabel:SetText("Show data-spine tab")

  local spineNote = spineRow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  spineNote:SetPoint("LEFT", spineLabel, "RIGHT", 12, 0)
  spineNote:SetPoint("RIGHT", spineRow, "RIGHT", 0, 0)
  spineNote:SetJustifyH("LEFT")
  spineNote:SetText("Verification view for the projection-layer redesign — the unified ledger computed from sibling sources. Reload required for tab to appear/disappear.")

  spineCB:SetScript("OnClick", function(self)
    TallyDB.ui = TallyDB.ui or {}
    TallyDB.ui.showSpineTab = self:GetChecked() and true or nil
    -- Live-register on enable so a reload is only needed to remove it.
    if TallyDB.ui.showSpineTab and ns.UI and ns.UI.MainFrame and ns.UI.CreateSpinePage
       and ns.UI.MainFrame.RegisterPage and not ns.UI.MainFrame:GetPage("Spine") then
      ns.UI.MainFrame:RegisterPage("Spine", ns.UI.CreateSpinePage)
    end
  end)

  -- ============================================================================
  -- SECTION 6: Danger zone — full data reset (testing aid + recovery path)
  -- ============================================================================

  local dangerHdr = makeSectionHeader(page, spineRow, "BOTTOMLEFT", 18, "DANGER ZONE")

  local resetRow = CreateFrame("Frame", nil, page)
  resetRow:SetPoint("TOPLEFT", dangerHdr, "BOTTOMLEFT", 0, -10)
  resetRow:SetPoint("RIGHT", page, "RIGHT", 0, 0)
  resetRow:SetHeight(24)

  local resetBtn = makeButton(resetRow, "Reset all Tally data", 200, function()
    StaticPopupDialogs["TALLY_RESET_DATA"] = StaticPopupDialogs["TALLY_RESET_DATA"] or {
      text = "Wipe Tally's net-worth snapshots, aggregates, overrides, inventory rollup, and setup state?\n\nConfig (strategy, retention, minimap, UI position) is preserved. The setup wizard will reopen so you can re-pick sources and strategy; Tally recomputes from your sibling sources on demand.\n\nThis cannot be undone.",
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
