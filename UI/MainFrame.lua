-- Tally — UI/MainFrame.lua
--
-- Tally's top-level frame and the projection-layer navigation shell
-- (TLY-83/-84). Singleton, lazy-created on first Show. Built on Cogworks'
-- `cw:CreateThemedMainFrame` for chrome (title bar, close button, resize
-- grip, ESC handler, persisted geometry).
--
-- Navigation is a **left bar** of sections (REDESIGN §4):
--
--   Live · Historical · Tools · Settings · Appearance
--
-- Live and Historical share the same windowed sub-tab strip (Ledger,
-- Inventory, and — once TLY-85 lands — Summary); they differ only in how
-- the active time window is set:
--   * Live      — implicit window: everything the spine has parsed.
--   * Historical — opens on a date-range picker; once a range is applied,
--                  shows the same sub-tabs scoped to it, with a back arrow
--                  returning to the picker.
--
-- Each section builds lazily into the shared content host on first open.
--
-- Public surface:
--   ns.UI.MainFrame:Get()
--   ns.UI.MainFrame:Show() / :Hide() / :Toggle() / :IsShown()
--   ns.UI.MainFrame:ShowSection(key[, subtab])  — deep-link a section/sub-tab
--   ns.UI.MainFrame:GetSubtabView(sectionKey, subtabKey)  — built view or nil
--   ns.UI.MainFrame:RefreshActivePage()

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

local MainFrame = {}
ns.UI.MainFrame = MainFrame

local frame            -- cw:CreateThemedMainFrame singleton
local leftBar          -- left-bar nav container
local host             -- content host (right of the left bar)
local sections = {}    -- key -> { label, build, instance, button }
local sectionOrder = {}
local activeSection

local LEFTBAR_WIDTH = 124

local DEFAULT_WIDTH = 860
local DEFAULT_HEIGHT = 520
local MIN_WIDTH = 680
local MIN_HEIGHT = 380
local MAX_WIDTH = 1600
local MAX_HEIGHT = 1100

local function uiDB()
  TallyDB.ui = TallyDB.ui or {}
  TallyDB.ui.mainFrame = TallyDB.ui.mainFrame or {}
  return TallyDB.ui
end

-- ============================================================================
-- Windowed sub-tab strip (shared by Live + Historical)
-- ============================================================================
--
-- A view registered as a sub-tab MAY implement `view:SetWindow(from, to,
-- label)` (window-aware: Summary, Ledger) and/or `view:Refresh()`. Window-
-- agnostic views (Inventory) simply omit SetWindow.

-- Sub-tab specs, shared across Live and Historical. `create(parent)` returns
-- the view frame. Guarded so increments can land views one at a time — a
-- spec whose builder isn't loaded yet is skipped.
local function subtabSpecs()
  local specs = {}
  if ns.UI.CreateSummaryView then
    specs[#specs + 1] = { key = "summary", label = "Summary",
                          create = function(p) return ns.UI.CreateSummaryView(p) end }
  end
  if ns.UI.CreateLedgerView then
    specs[#specs + 1] = { key = "ledger", label = "Ledger",
                          create = function(p) return ns.UI.CreateLedgerView(p) end }
  end
  if ns.UI.CreateInventoryPage then
    specs[#specs + 1] = { key = "inventory", label = "Inventory",
                          create = function(p) return ns.UI.CreateInventoryPage(p) end }
  end
  return specs
end

-- Build a windowed sub-tab strip into `parent`. Returns a frame with:
--   :SetWindow(from, to, label)  — re-scope all built views + refresh
--   :Refresh()
--   :ShowSubtab(key)
--   :GetView(key)
local function createWindowedTabs(parent)
  local cw = getCogworks()
  local container = CreateFrame("Frame", nil, parent)
  container:SetAllPoints(parent)

  local win = { from = 0, to = nil, label = "Live" }
  local instances = {}

  local function applyWindow(v)
    if not v then return end
    if v.SetWindow then v:SetWindow(win.from, win.to, win.label) end
    if v.Refresh then v:Refresh() end
  end

  local specs = subtabSpecs()
  if not (cw and cw.CreateTabPanel) or #specs == 0 then
    local fs = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetPoint("CENTER")
    fs:SetText("No views available — update Cogworks.")
    function container:SetWindow() end
    function container:Refresh() end
    function container:ShowSubtab() end
    function container:GetView() return nil end
    return container
  end

  local tabs = {}
  for _, st in ipairs(specs) do
    tabs[#tabs + 1] = {
      key = st.key, label = st.label,
      build = function(tabParent)
        local v = st.create(tabParent)
        if v then
          -- CreateTabPanel does not auto-anchor the built frame; fill the
          -- tab content area so the view lays out.
          v:ClearAllPoints()
          v:SetPoint("TOPLEFT", tabParent, "TOPLEFT", 4, -4)
          v:SetPoint("BOTTOMRIGHT", tabParent, "BOTTOMRIGHT", -4, 4)
          instances[st.key] = v
          applyWindow(v)
        end
        return v
      end,
    }
  end

  local panel = cw:CreateTabPanel(container, {
    tabs = tabs,
    initialTab = specs[1].key,
    tabHeight = 24,
    onTabChange = function(key)
      applyWindow(instances[key])
    end,
  })
  panel:SetAllPoints(container)

  function container:SetWindow(from, to, label)
    win.from, win.to, win.label = from, to, label
    for _, v in pairs(instances) do applyWindow(v) end
  end
  function container:Refresh()
    for _, v in pairs(instances) do if v.Refresh then v:Refresh() end end
  end
  function container:ShowSubtab(key)
    if panel.SetActiveTab then panel:SetActiveTab(key) end
  end
  function container:GetView(key) return instances[key] end

  return container
end

-- ============================================================================
-- Historical date-range picker (TLY-84)
-- ============================================================================

local DAY = 86400

-- Parse "YYYY-MM-DD" to a local-time epoch (start of day), or nil.
local function parseDate(str)
  if type(str) ~= "string" then return nil end
  local y, m, d = str:match("^%s*(%d%d%d%d)%-(%d%d?)%-(%d%d?)%s*$")
  if not y then return nil end
  return time({ year = tonumber(y), month = tonumber(m), day = tonumber(d),
                hour = 0, min = 0, sec = 0 })
end

-- Build the Historical section: a picker that, on Apply, swaps to the
-- windowed sub-tab strip scoped to the chosen range, with a back arrow.
local function buildHistoricalSection(parent)
  local section = CreateFrame("Frame", nil, parent)
  section:SetAllPoints(parent)

  -- ── Picker pane ────────────────────────────────────────────────────────
  local picker = CreateFrame("Frame", nil, section)
  picker:SetAllPoints(section)

  local title = picker:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", picker, "TOPLEFT", 4, -4)
  title:SetText("Historical")
  title:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local intro = picker:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  intro:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  intro:SetPoint("RIGHT", picker, "RIGHT", -8, 0)
  intro:SetJustifyH("LEFT")
  intro:SetText("Pick a date range to view your ledger and summary for that period. "
    .. "History reaches back as far as your sibling addons keep it.")

  -- Manual range inputs.
  local function makeDateInput(label, anchor, yoff)
    local row = CreateFrame("Frame", nil, picker)
    row:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, yoff)
    row:SetSize(260, 24)
    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", row, "LEFT", 0, 0)
    lbl:SetWidth(46)
    lbl:SetJustifyH("LEFT")
    lbl:SetText(label)
    local edit = CreateFrame("EditBox", nil, row, "BackdropTemplate")
    edit:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
    edit:SetSize(110, 22)
    edit:SetAutoFocus(false)
    edit:SetFontObject("GameFontHighlight")
    edit:SetTextInsets(6, 6, 0, 0)
    edit:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
    })
    edit:SetBackdropColor(themeColor("bgDark", { 0.04, 0.04, 0.07, 1 }))
    edit:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))
    local hint = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    hint:SetPoint("LEFT", edit, "RIGHT", 6, 0)
    hint:SetText("YYYY-MM-DD")
    return row, edit
  end

  local fromRow, fromEdit = makeDateInput("From", intro, -16)
  local toRow,   toEdit   = makeDateInput("To",   fromRow, -6)
  toEdit:SetText(date("%Y-%m-%d", time()))
  fromEdit:SetText(date("%Y-%m-%d", time() - 30 * DAY))

  -- Quick presets.
  local presetHdr = picker:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  presetHdr:SetPoint("TOPLEFT", toRow, "BOTTOMLEFT", 0, -14)
  presetHdr:SetText("Quick ranges")

  local PRESETS = {
    { label = "Last 30 days",  from = function() return time() - 30 * DAY end,  to = function() return time() end },
    { label = "Last 90 days",  from = function() return time() - 90 * DAY end,  to = function() return time() end },
    { label = "This month",    from = function() return parseDate(date("%Y-%m-01")) end, to = function() return time() end },
    { label = "Last 12 months",from = function() return time() - 365 * DAY end, to = function() return time() end },
  }

  -- Forward declaration: openRange swaps to the result pane.
  local openRange

  local presetRow = CreateFrame("Frame", nil, picker)
  presetRow:SetPoint("TOPLEFT", presetHdr, "BOTTOMLEFT", 0, -6)
  presetRow:SetSize(560, 26)
  local px = 0
  for _, p in ipairs(PRESETS) do
    local b = CreateFrame("Button", nil, presetRow, "UIPanelButtonTemplate")
    b:SetSize(120, 22)
    b:SetPoint("LEFT", presetRow, "LEFT", px, 0)
    b:SetText(p.label)
    b:SetScript("OnClick", function()
      openRange(p.from(), p.to(), p.label)
    end)
    px = px + 126
  end

  -- Apply (manual).
  local applyBtn = CreateFrame("Button", nil, picker, "UIPanelButtonTemplate")
  applyBtn:SetSize(120, 24)
  applyBtn:SetPoint("TOPLEFT", presetRow, "BOTTOMLEFT", 0, -16)
  applyBtn:SetText("Apply range")

  local err = picker:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  err:SetPoint("LEFT", applyBtn, "RIGHT", 10, 0)
  err:SetTextColor(0.9, 0.4, 0.4)

  applyBtn:SetScript("OnClick", function()
    local f = parseDate(fromEdit:GetText())
    local t = parseDate(toEdit:GetText())
    if not f or not t then
      err:SetText("Enter dates as YYYY-MM-DD.")
      return
    end
    if t < f then f, t = t, f end
    t = t + DAY - 1  -- inclusive end-of-day
    err:SetText("")
    openRange(f, t, date("%b %d", f) .. " – " .. date("%b %d", t))
  end)

  -- ── Result pane ────────────────────────────────────────────────────────
  local result = CreateFrame("Frame", nil, section)
  result:SetAllPoints(section)
  result:Hide()

  local backBtn = CreateFrame("Button", nil, result, "UIPanelButtonTemplate")
  backBtn:SetSize(90, 22)
  backBtn:SetPoint("TOPLEFT", result, "TOPLEFT", 0, 0)
  backBtn:SetText("< Back")

  local rangeLabel = result:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  rangeLabel:SetPoint("LEFT", backBtn, "RIGHT", 10, 0)
  rangeLabel:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local tabsHost = CreateFrame("Frame", nil, result)
  tabsHost:SetPoint("TOPLEFT", backBtn, "BOTTOMLEFT", 0, -6)
  tabsHost:SetPoint("BOTTOMRIGHT", result, "BOTTOMRIGHT", 0, 0)

  local tabs  -- created lazily on first openRange

  backBtn:SetScript("OnClick", function()
    result:Hide()
    picker:Show()
  end)

  openRange = function(from, to, label)
    if not tabs then tabs = createWindowedTabs(tabsHost) end
    rangeLabel:SetText(label or "Range")
    tabs:SetWindow(from, to, label)
    picker:Hide()
    result:Show()
  end

  -- Expose for deep-linking (rare; Historical normally opens on the picker).
  section.tabs = function() return tabs end
  return section
end

-- ============================================================================
-- Tools section (minimal until TLY-89)
-- ============================================================================

local function buildToolsSection(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetAllPoints(parent)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 4, -4)
  title:SetText("Tools")
  title:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  note:SetPoint("RIGHT", f, "RIGHT", -8, 0)
  note:SetJustifyH("LEFT")
  note:SetText("Re-read your sibling addons, or export the unified ledger for "
    .. "offline analysis. The full CSV export tooling lands in a later update.")

  local reparse = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  reparse:SetSize(180, 24)
  reparse:SetPoint("TOPLEFT", note, "BOTTOMLEFT", 0, -16)
  reparse:SetText("Re-parse sibling sources")
  reparse:SetScript("OnClick", function()
    local PC = ns.Spine and ns.Spine.ParseCache
    if PC and PC.Refresh then
      if ns.Output then ns.Output:Info("Re-parsing sibling sources…") end
      PC:Refresh()
    elseif ns.Output then
      ns.Output:Error("Data spine unavailable.")
    end
  end)

  local export = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  export:SetSize(180, 24)
  export:SetPoint("TOPLEFT", reparse, "BOTTOMLEFT", 0, -8)
  export:SetText("Export unified ledger")
  export:SetScript("OnClick", function()
    local UL = ns.Spine and ns.Spine.UnifiedLedger
    if not (UL and UL:IsReady()) then
      if ns.Output then ns.Output:Warn("Open Live first so the ledger is parsed, then export.") end
      return
    end
    local lines = { "kind,atTime,charKey,realm,itemID,count,copper,sources" }
    for _, r in ipairs(UL:Query()) do
      local srcs = {}
      for s in pairs(r.sources or {}) do srcs[#srcs + 1] = s end
      table.sort(srcs)
      lines[#lines + 1] = string.format("%s,%d,%s,%s,%s,%d,%d,%s",
        r.kind or "?", r.atTime or 0, r.charKey or "?",
        (r.realm and r.realm.key) or "?", tostring(r.itemID or ""),
        r.count or 0, r.copper or 0, table.concat(srcs, "+"))
    end
    if ns.Output then
      ns.Output:Inspect(table.concat(lines, "\n"),
        "Tally unified ledger (CSV) — copy into a spreadsheet or the offline service.")
    end
  end)

  return f
end

-- ============================================================================
-- Frame + left bar
-- ============================================================================

local function registerSection(key, label, build)
  if sections[key] then return end
  sections[key] = { label = label, build = build, instance = nil, button = nil }
  sectionOrder[#sectionOrder + 1] = key
end

-- Defined once, on first build(), so the page builders (loaded after this
-- file) exist by the time they're referenced.
local function defineSections()
  if #sectionOrder > 0 then return end
  registerSection("live", "Live", function(parent)
    local f = createWindowedTabs(parent)
    f:SetWindow(0, nil, "Live")
    return f
  end)
  registerSection("historical", "Historical", buildHistoricalSection)
  registerSection("tools", "Tools", buildToolsSection)
  registerSection("settings", "Settings", function(parent)
    return ns.UI.CreateSettingsPage and ns.UI.CreateSettingsPage(parent)
  end)
  registerSection("appearance", "Appearance", function(parent)
    return ns.UI.CreateAppearancePage and ns.UI.CreateAppearancePage(parent)
  end)
end

local function styleSectionButton(btn, selected)
  if selected then
    btn.bg:SetColorTexture(themeColor("brass", { 0.83, 0.63, 0.09, 0.22 }))
    btn.bg:SetAlpha(0.30)
    btn.label:SetTextColor(themeColor("brass", { 0.95, 0.78, 0.25, 1 }))
  else
    btn.bg:SetColorTexture(0, 0, 0, 0)
    btn.label:SetTextColor(0.82, 0.82, 0.82, 1)
  end
end

local function showSection(key)
  if not sections[key] then return end
  activeSection = key
  uiDB().lastSection = key
  for k, sec in pairs(sections) do
    if sec.button then styleSectionButton(sec.button, k == key) end
  end
  for k, sec in pairs(sections) do
    if sec.instance and k ~= key then sec.instance:Hide() end
  end
  local sec = sections[key]
  if not sec.instance then
    local built = sec.build(host)
    if not built then
      built = CreateFrame("Frame", nil, host)
      local fs = built:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      fs:SetPoint("CENTER")
      fs:SetText(sec.label .. " — unavailable.")
    end
    built:ClearAllPoints()
    built:SetPoint("TOPLEFT", host, "TOPLEFT", 8, -8)
    built:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -8, 8)
    sec.instance = built
  end
  sec.instance:Show()
  if sec.instance.Refresh then sec.instance:Refresh() end
end

local function buildLeftBar()
  leftBar = CreateFrame("Frame", nil, frame.content)
  leftBar:SetPoint("TOPLEFT", frame.content, "TOPLEFT", 4, -4)
  leftBar:SetPoint("BOTTOMLEFT", frame.content, "BOTTOMLEFT", 4, 4)
  leftBar:SetWidth(LEFTBAR_WIDTH)

  local sep = leftBar:CreateTexture(nil, "ARTWORK")
  sep:SetPoint("TOPRIGHT", leftBar, "TOPRIGHT", 0, 0)
  sep:SetPoint("BOTTOMRIGHT", leftBar, "BOTTOMRIGHT", 0, 0)
  sep:SetWidth(1)
  sep:SetColorTexture(themeColor("border", { 0.30, 0.30, 0.40, 1 }))

  local y = 0
  for _, key in ipairs(sectionOrder) do
    local sec = sections[key]
    local btn = CreateFrame("Button", nil, leftBar)
    btn:SetPoint("TOPLEFT", leftBar, "TOPLEFT", 0, y)
    btn:SetPoint("TOPRIGHT", leftBar, "TOPRIGHT", -2, y)
    btn:SetHeight(30)
    btn.bg = btn:CreateTexture(nil, "BACKGROUND")
    btn.bg:SetAllPoints()
    btn.bg:SetColorTexture(0, 0, 0, 0)
    btn.label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    btn.label:SetPoint("LEFT", btn, "LEFT", 10, 0)
    btn.label:SetText(sec.label)
    btn:SetScript("OnEnter", function(self)
      if activeSection ~= key then self.bg:SetColorTexture(1, 1, 1, 0.06) end
    end)
    btn:SetScript("OnLeave", function(self)
      if activeSection ~= key then self.bg:SetColorTexture(0, 0, 0, 0) end
    end)
    btn:SetScript("OnClick", function() showSection(key) end)
    sec.button = btn
    y = y - 32
  end
end

local function build()
  if frame then return frame end

  local cw = getCogworks()
  if not (cw and cw.CreateThemedMainFrame) then
    error("Tally: UI/MainFrame requires Cogworks-1.0 v0.13+ (CreateThemedMainFrame missing)", 2)
  end

  local addonVer = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("Tally", "Version"))
                or (GetAddOnMetadata and GetAddOnMetadata("Tally", "Version"))

  frame = cw:CreateThemedMainFrame({
    name        = "TallyMainFrame",
    title       = "|cff7fbfffTally|r",
    versionText = addonVer,
    defaultSize = { w = DEFAULT_WIDTH, h = DEFAULT_HEIGHT },
    minSize     = { w = MIN_WIDTH,     h = MIN_HEIGHT     },
    maxSize     = { w = MAX_WIDTH,     h = MAX_HEIGHT     },
    saveTo      = uiDB().mainFrame,
    closeOnEscape = true,
  })

  -- Tally drives its own left-bar nav inside `content`; hide the primitive's
  -- sidebar slot and let content span the full frame.
  frame.sidebar:Hide()
  frame.content:ClearAllPoints()
  frame.content:SetPoint("TOPLEFT",     frame.titleBar, "BOTTOMLEFT",  0, -2)
  frame.content:SetPoint("BOTTOMRIGHT", frame,          "BOTTOMRIGHT", -4, 4)

  defineSections()
  buildLeftBar()

  -- Content host: right of the left bar.
  host = CreateFrame("Frame", nil, frame.content)
  host:SetPoint("TOPLEFT", leftBar, "TOPRIGHT", 6, 0)
  host:SetPoint("BOTTOMRIGHT", frame.content, "BOTTOMRIGHT", -4, 2)

  -- Refresh active section on resize (throttled).
  local lastResizeRefresh = 0
  frame:HookScript("OnSizeChanged", function()
    local now = GetTime and GetTime() or 0
    if now - lastResizeRefresh < 0.1 then return end
    lastResizeRefresh = now
    MainFrame:RefreshActivePage()
  end)

  tinsert(UISpecialFrames, "TallyMainFrame")
  return frame
end

-- ============================================================================
-- Public API
-- ============================================================================

function MainFrame:Get()
  return build()
end

function MainFrame:Show()
  build()
  if not activeSection then
    local saved = uiDB().lastSection
    showSection((saved and sections[saved]) and saved or sectionOrder[1])
  end
  frame:Show()
end

function MainFrame:Hide()
  if frame then frame:Hide() end
end

function MainFrame:IsShown()
  return frame and frame:IsShown()
end

function MainFrame:Toggle()
  if self:IsShown() then self:Hide() else self:Show() end
end

function MainFrame:GetActiveSection()
  return activeSection
end

-- Deep-link a section, optionally a sub-tab within Live's strip.
function MainFrame:ShowSection(key, subtab)
  build()
  if not sections[key] then return end
  if not frame:IsShown() then frame:Show() end
  showSection(key)
  if subtab then
    local sec = sections[key]
    if sec.instance and sec.instance.ShowSubtab then
      sec.instance:ShowSubtab(subtab)
    end
  end
end

-- The built view for a Live sub-tab (e.g. "inventory"), or nil. Used by
-- deep-link helpers that need to call a view method after navigating.
function MainFrame:GetSubtabView(sectionKey, subtabKey)
  local sec = sections[sectionKey]
  if sec and sec.instance and sec.instance.GetView then
    return sec.instance:GetView(subtabKey)
  end
  return nil
end

function MainFrame:RefreshActivePage()
  if not activeSection then return end
  local sec = sections[activeSection]
  if sec and sec.instance and sec.instance.Refresh then
    sec.instance:Refresh()
  end
end
