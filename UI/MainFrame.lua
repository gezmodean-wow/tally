-- Tally — UI/MainFrame.lua
--
-- Tally's top-level frame. Singleton, lazy-created on first Show. Built on
-- Cogworks v0.13's `cw:CreateThemedMainFrame` for chrome (title bar, close
-- button, summary bar, resize grip, ESC handler, persisted geometry, uiScale
-- subscription) — Tally's pages drive a `cw:CreateTabPanel` inside the
-- frame's `content` region; the sidebar slot the primitive provides is
-- hidden so the existing tab-style UX is preserved.
--
-- Public surface (unchanged):
--   ns.UI.MainFrame:Get()           — singleton, creates on first call
--   ns.UI.MainFrame:Show()          — creates if needed and shows
--   ns.UI.MainFrame:Hide()
--   ns.UI.MainFrame:Toggle()
--   ns.UI.MainFrame:RegisterPage(name, createFn)  — createFn(parent) -> Frame
--   ns.UI.MainFrame:ShowPage(name)
--   ns.UI.MainFrame:GetPage(name)
--   ns.UI.MainFrame:GetActivePage()
--   ns.UI.MainFrame:RefreshActivePage()
--
-- Pages register at PLAYER_LOGIN; the tab panel is built on first :Show()
-- using the pages registered up to that point. Late-arriving pages (after
-- the panel is built) are dropped with a warning — fix by registering
-- earlier.

local addonName, ns = ...
ns.UI = ns.UI or {}

local function getCogworks()
  return LibStub and LibStub("Cogworks-1.0", true) or nil
end

local MainFrame = {}
ns.UI.MainFrame = MainFrame

local frame -- singleton from cw:CreateThemedMainFrame
local pages = {}        -- { [name] = { create = fn, instance = frame|nil } }
local pageOrder = {}    -- registration order
local activePage
local tabPanel          -- cw:CreateTabPanel instance, lazy-built on first :Show()

local DEFAULT_WIDTH = 720
local DEFAULT_HEIGHT = 460
local MIN_WIDTH = 600
local MIN_HEIGHT = 360
local MAX_WIDTH = 1600
local MAX_HEIGHT = 1100

local function uiDB()
  TallyDB.ui = TallyDB.ui or {}
  TallyDB.ui.mainFrame = TallyDB.ui.mainFrame or {}
  return TallyDB.ui
end

-- ============================================================================
-- Frame construction
-- ============================================================================

local function build()
  if frame then return frame end

  local cw = getCogworks()
  if not (cw and cw.CreateThemedMainFrame) then
    -- Cogworks v0.13+ unavailable. Surface a clear failure rather than
    -- silently producing a broken UI; this should only happen if .pkgmeta
    -- regresses below v0.13.0.
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

  -- Hide the sidebar slot — Tally uses tab-panel UX, not sidebar nav.
  -- Re-anchor `content` directly under the title bar so the tab panel
  -- gets the full frame width.
  frame.sidebar:Hide()
  frame.content:ClearAllPoints()
  frame.content:SetPoint("TOPLEFT",     frame.titleBar, "BOTTOMLEFT",  0, -2)
  frame.content:SetPoint("BOTTOMRIGHT", frame,          "BOTTOMRIGHT", -4, 4)

  -- Refresh active page on resize (CreateThemedMainFrame's grip persists
  -- geometry on drag-stop; we add the live-throttled refresh on top).
  local lastResizeRefresh = 0
  frame:HookScript("OnSizeChanged", function()
    local now = GetTime and GetTime() or 0
    if now - lastResizeRefresh < 0.1 then return end
    lastResizeRefresh = now
    if MainFrame.RefreshActivePage then MainFrame:RefreshActivePage() end
  end)

  -- Make `/` and ESC behave like other addon frames — UISpecialFrames lets
  -- the user dismiss with ESC even though we're already wired into the
  -- primitive's ESC handler. Belt + suspenders for legacy callers.
  tinsert(UISpecialFrames, "TallyMainFrame")

  return frame
end

-- ============================================================================
-- Tab panel
-- ============================================================================

local function buildTabPanel()
  if tabPanel then return tabPanel end
  if #pageOrder == 0 then return nil end
  build()

  local cw = getCogworks()
  if not (cw and cw.CreateTabPanel) then
    local fs = frame.content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
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
      build = function(parent)
        if entry.instance then return entry.instance end
        local page = entry.create(parent)
        if not page then return nil end
        page:ClearAllPoints()
        page:SetPoint("TOPLEFT",     parent, "TOPLEFT",     8, -8)
        page:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -8, 8)
        entry.instance = page
        return page
      end,
    }
  end

  local saved = uiDB().lastTab
  local initial = (saved and pages[saved]) and saved or pageOrder[1]

  tabPanel = cw:CreateTabPanel(frame.content, {
    tabs        = tabs,
    initialTab  = initial,
    tabHeight   = 26,
    onTabChange = function(key)
      activePage = key
      uiDB().lastTab = key
      if frame.SetSummary then frame:SetSummary("— " .. key) end
      local entry = pages[key]
      if entry and entry.instance and entry.instance.Refresh then
        entry.instance:Refresh()
      end
    end,
  })
  tabPanel:SetPoint("TOPLEFT",     frame.content, "TOPLEFT",     8, -2)
  tabPanel:SetPoint("BOTTOMRIGHT", frame.content, "BOTTOMRIGHT", -8, 2)

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
    if not frame:IsShown() then frame:Show() end
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

function MainFrame:RefreshActivePage()
  if not activePage then return end
  local entry = pages[activePage]
  if entry and entry.instance and entry.instance.Refresh then
    entry.instance:Refresh()
  end
end
