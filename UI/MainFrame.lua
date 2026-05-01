-- Tally — UI/MainFrame.lua
--
-- Tally's top-level frame. Singleton, lazy-created on first Show. Title bar
-- with close button, then a Cogworks tab panel (lazy-builds each page on
-- first activation).
--
-- Public surface:
--   ns.UI.MainFrame:Get()           — singleton, creates on first call
--   ns.UI.MainFrame:Show()          — creates if needed and shows
--   ns.UI.MainFrame:Hide()
--   ns.UI.MainFrame:Toggle()
--   ns.UI.MainFrame:RegisterPage(name, createFn)  — createFn(parent) -> page Frame
--   ns.UI.MainFrame:ShowPage(name)
--   ns.UI.MainFrame:GetPage(name)
--   ns.UI.MainFrame:GetActivePage()
--
-- Pages register at PLAYER_LOGIN; the tab panel is built on first :Show()
-- using the pages registered up to that point. Late-arriving pages (after
-- the panel is built) get a warning and are dropped — fix by registering
-- earlier or by filing a Cogworks issue for incremental tab addition.

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

local frame -- singleton
local pages = {}        -- { [name] = { create = fn, instance = frame|nil } }
local pageOrder = {}    -- registration order
local activePage
local tabPanel          -- cw:CreateTabPanel instance, lazy-built on first :Show()

local DEFAULT_WIDTH = 720
local DEFAULT_HEIGHT = 460

local function uiDB()
  TallyDB.ui = TallyDB.ui or {}
  TallyDB.ui.mainFrame = TallyDB.ui.mainFrame or {}
  return TallyDB.ui
end

local function savePosition(self)
  local point, _, relPoint, x, y = self:GetPoint()
  if not point then return end
  local store = uiDB().mainFrame
  store.point = point
  store.relPoint = relPoint
  store.x = x
  store.y = y
end

local function restorePosition(self)
  local store = uiDB().mainFrame
  if store.point and store.x ~= nil and store.y ~= nil then
    self:ClearAllPoints()
    self:SetPoint(store.point, UIParent, store.relPoint or store.point, store.x, store.y)
  else
    self:SetPoint("CENTER")
  end
end

local function build()
  if frame then return frame end

  frame = CreateFrame("Frame", "TallyMainFrame", UIParent, "BackdropTemplate")
  frame:SetSize(DEFAULT_WIDTH, DEFAULT_HEIGHT)
  frame:SetFrameStrata("HIGH")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    savePosition(self)
  end)
  frame:SetClampedToScreen(true)
  frame:Hide()
  restorePosition(frame)

  -- Backdrop fill.
  if frame.SetBackdrop then
    frame:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      edgeSize = 1,
      insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    frame:SetBackdropColor(themeColor("bg", { 0.08, 0.08, 0.12, 0.95 }))
    frame:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))
  end

  -- Title bar.
  local titleBar = CreateFrame("Frame", nil, frame)
  titleBar:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
  titleBar:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
  titleBar:SetHeight(28)
  local tbBg = titleBar:CreateTexture(nil, "BACKGROUND")
  tbBg:SetAllPoints()
  tbBg:SetColorTexture(themeColor("header", { 0.15, 0.15, 0.20, 1 }))

  local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("LEFT", titleBar, "LEFT", 12, 0)
  title:SetText("|cff7fbfffTally|r")
  title:SetTextColor(themeColor("text", { 0.90, 0.90, 0.92, 1 }))

  -- Subtitle on the title bar — name of the active page.
  local subtitle = titleBar:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  subtitle:SetPoint("LEFT", title, "RIGHT", 8, 0)
  subtitle:SetTextColor(themeColor("textDim", { 0.6, 0.6, 0.6, 1 }))
  frame.subtitle = subtitle

  -- Close button.
  local close = CreateFrame("Button", nil, titleBar, "UIPanelCloseButton")
  close:SetPoint("RIGHT", titleBar, "RIGHT", 4, 0)
  close:SetScript("OnClick", function() frame:Hide() end)

  -- Body — fills the area below the title bar. The Cogworks tab panel
  -- lives inside this body once :Show() is called and pages are known.
  local body = CreateFrame("Frame", nil, frame)
  body:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, -2)
  body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
  frame.body = body

  -- ESC closes the frame, mirroring most WoW addon frames.
  tinsert(UISpecialFrames, "TallyMainFrame")

  return frame
end

-- ============================================================================
-- Tab panel (Cogworks primitive)
-- ============================================================================
-- Builds the tab panel from the currently registered pages. Each tab's
-- `build` callback creates the page lazily on first activation and stores
-- the resulting frame back into pages[name].instance so subsequent
-- ShowPage calls can find it for Refresh.

local function buildTabPanel()
  if tabPanel then return tabPanel end
  if #pageOrder == 0 then return nil end
  build()

  local cw = getCogworks()
  if not (cw and cw.CreateTabPanel) then
    -- Cogworks unavailable — render a stub message so the user knows what
    -- went wrong rather than seeing an empty body.
    local fs = frame.body:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("CENTER")
    fs:SetText("Tally requires Cogworks-1.0 with CreateTabPanel.")
    return nil
  end

  local tabs = {}
  for _, name in ipairs(pageOrder) do
    local entry = pages[name]
    tabs[#tabs + 1] = {
      key   = name,
      label = name,
      build = function(content)
        if entry.instance then return entry.instance end
        local page = entry.create(content)
        if not page then return nil end
        page:ClearAllPoints()
        page:SetPoint("TOPLEFT",     content, "TOPLEFT",     8, -8)
        page:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", -8, 8)
        entry.instance = page
        return page
      end,
    }
  end

  -- Initial tab = saved last tab if it's still registered, else first.
  local saved = uiDB().lastTab
  local initial = (saved and pages[saved]) and saved or pageOrder[1]

  tabPanel = cw:CreateTabPanel(frame.body, {
    tabs        = tabs,
    initialTab  = initial,
    tabHeight   = 26,
    onTabChange = function(key)
      activePage = key
      uiDB().lastTab = key
      if frame.subtitle then frame.subtitle:SetText("— " .. key) end
      local entry = pages[key]
      if entry and entry.instance and entry.instance.Refresh then
        entry.instance:Refresh()
      end
    end,
  })
  tabPanel:SetPoint("TOPLEFT",     frame.body, "TOPLEFT",     8, -2)
  tabPanel:SetPoint("BOTTOMRIGHT", frame.body, "BOTTOMRIGHT", -8, 2)

  return tabPanel
end

-- ============================================================================
-- Public API
-- ============================================================================

function MainFrame:Get()
  return build()
end

function MainFrame:Show()
  build()
  buildTabPanel()
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

function MainFrame:GetActivePage()
  return activePage
end

function MainFrame:RegisterPage(name, createFn)
  if pages[name] then return end
  if tabPanel then
    -- Tab panel already constructed; CreateTabPanel doesn't currently
    -- support post-construction tab addition. Surface a warning so the
    -- developer notices and shifts registration earlier (or files a
    -- Cogworks issue for incremental tab support).
    print(string.format("|cffff8000Tally:|r late page registration ignored — '%s' "
      .. "registered after main frame was first shown.", name))
    return
  end
  pages[name] = { create = createFn, instance = nil }
  pageOrder[#pageOrder + 1] = name
end

function MainFrame:GetPage(name)
  local entry = pages[name]
  return entry and entry.instance or nil
end

function MainFrame:ShowPage(name)
  build()
  buildTabPanel()
  if not pages[name] then return end
  if tabPanel and tabPanel.SetActiveTab then
    -- Showing the frame and setting the tab can race when called in either
    -- order; doing the show first ensures CreateTabPanel's build callback
    -- has a visible host (some pages measure parent width on creation).
    if not frame:IsShown() then frame:Show() end
    -- CreateTabPanel:SetActiveTab is a no-op when the requested tab is
    -- already active. If the caller asked for the active page (a common
    -- case after an inventory-changed refresh fires while the user is on
    -- that page already), still drive the page's :Refresh() so live data
    -- updates surface.
    if activePage == name then
      local entry = pages[name]
      if entry and entry.instance and entry.instance.Refresh then
        entry.instance:Refresh()
      end
    else
      tabPanel:SetActiveTab(name)
    end
  end
end

-- Fire :Refresh on the currently active page if it has one. Used by
-- inventory / ledger callbacks that want the open page to re-pull data
-- without the user clicking around.
function MainFrame:RefreshActivePage()
  if not activePage then return end
  local entry = pages[activePage]
  if entry and entry.instance and entry.instance.Refresh then
    entry.instance:Refresh()
  end
end
