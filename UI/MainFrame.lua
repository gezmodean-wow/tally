-- Tally — UI/MainFrame.lua
--
-- Tally's top-level frame. Singleton, lazy-created on first Show. Title bar
-- with close button, body region for the active page. Pages register
-- themselves via ns.UI.MainFrame:RegisterPage(name, createFn). The first
-- registered page is the default; future passes will add a tab strip.
--
-- Public surface:
--   ns.UI.MainFrame:Get()           — singleton, creates on first call
--   ns.UI.MainFrame:Show()          — creates if needed and shows
--   ns.UI.MainFrame:Hide()
--   ns.UI.MainFrame:Toggle()
--   ns.UI.MainFrame:RegisterPage(name, createFn)  — createFn(parent) -> page Frame
--   ns.UI.MainFrame:ShowPage(name)

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

local DEFAULT_WIDTH = 720
local DEFAULT_HEIGHT = 460

local function build()
  if frame then return frame end

  frame = CreateFrame("Frame", "TallyMainFrame", UIParent, "BackdropTemplate")
  frame:SetSize(DEFAULT_WIDTH, DEFAULT_HEIGHT)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("HIGH")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  frame:SetClampedToScreen(true)
  frame:Hide()

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

  -- Body — hosts the active page.
  local body = CreateFrame("Frame", nil, frame)
  body:SetPoint("TOPLEFT", titleBar, "BOTTOMLEFT", 0, 0)
  body:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
  frame.body = body

  -- ESC closes the frame, mirroring most WoW addon frames.
  tinsert(UISpecialFrames, "TallyMainFrame")

  return frame
end

function MainFrame:Get()
  return build()
end

function MainFrame:Show()
  build():Show()
  -- If no active page, default to the first registered.
  if not activePage and pageOrder[1] then
    self:ShowPage(pageOrder[1])
  end
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
  pages[name] = { create = createFn, instance = nil }
  pageOrder[#pageOrder + 1] = name
end

function MainFrame:ShowPage(name)
  build()
  local entry = pages[name]
  if not entry then return end

  -- Hide previous.
  for _, other in pairs(pages) do
    if other.instance and other ~= entry then other.instance:Hide() end
  end

  -- Lazy-create the page.
  if not entry.instance then
    local page = entry.create(frame.body)
    if not page then return end
    page:ClearAllPoints()
    page:SetPoint("TOPLEFT", frame.body, "TOPLEFT", 8, -8)
    page:SetPoint("BOTTOMRIGHT", frame.body, "BOTTOMRIGHT", -8, 8)
    entry.instance = page
  end

  entry.instance:Show()
  activePage = name
  if frame.subtitle then frame.subtitle:SetText("— " .. name) end

  -- Pages may opt-in to OnShow refresh by exposing a Refresh method.
  if entry.instance.Refresh then entry.instance:Refresh() end
end
