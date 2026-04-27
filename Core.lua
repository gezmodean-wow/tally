-- Tally — Core.lua
--
-- Entry point. Wires Cogworks registration, Syndicator callbacks, slash
-- commands, and the LibDataBroker launcher (with running net-worth text).

local addonName, ns = ...

-- ============================================================================
-- Syndicator hard dependency
-- ============================================================================
if not (Syndicator and Syndicator.API) then
  print("|cffff4040Tally:|r Syndicator is required. Install it from CurseForge or Wago.")
  return
end

-- ============================================================================
-- Cogworks integration
-- ============================================================================
local Cogworks
if LibStub then
  Cogworks = LibStub("Cogworks-1.0", true)
  if Cogworks and Cogworks.RegisterAddon then
    Cogworks:RegisterAddon(addonName, ns)
  end
end
ns.Cogworks = Cogworks
ns.cw = Cogworks

-- ============================================================================
-- SavedVariables
-- ============================================================================
TallyDB = TallyDB or {}
TallyCharDB = TallyCharDB or {}
TallyDB.netWorth = TallyDB.netWorth or { strategy = "DBRegionMarketAvg" }
TallyDB.minimap = TallyDB.minimap or { hide = false }

-- ============================================================================
-- Event dispatch
-- ============================================================================
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:SetScript("OnEvent", function(_, event, ...)
  local handler = ns[event]
  if handler then handler(ns, ...) end
end)

function ns:PLAYER_LOGIN()
  if ns.Inventory and ns.Inventory.RegisterSyndicatorCallbacks then
    ns.Inventory:RegisterSyndicatorCallbacks()
  end
  -- Invalidate research cache on inventory updates so consumers always see
  -- fresh ownership/valuation. Cogworks event bus is the broadcast channel.
  if Cogworks and Cogworks.RegisterCallback and Cogworks.Events then
    Cogworks.RegisterCallback(addonName, Cogworks.Events.InventoryChanged, function()
      if ns.Research then ns.Research:Invalidate() end
    end)
  end
end

-- ============================================================================
-- Public API (stopgap until Cogworks issue #6 lands a versioned API registry)
-- ============================================================================
-- Sibling cogs probe `_G.TallyAPI` and check { major, minor } before calling.
-- Major bumps are breaking; minor bumps are additive.
_G.TallyAPI = {
  major = 1,
  minor = 0,
  api = {
    GetItemResearch = function(input, itemName) return ns.Research:GetRecord(input, itemName) end,
    InvalidateItemResearch = function(itemKey) ns.Research:Invalidate(itemKey) end,
    GetNetWorthSnapshot = function() return ns.NetWorth:Snapshot() end,
    GetInventoryRollup = function() return ns.Inventory:Get() end,
  },
}

-- ============================================================================
-- Slash commands
-- ============================================================================
local function printHelp()
  local prefix = "|cff7fbfffTally|r"
  print(prefix .. " — Personal Capital for WoW.")
  print("  /tally networth (or /tly nw) — print current net worth (saleable items only)")
  print("  /tally ownedworth (or /tly ow) — print owned worth (includes bound items)")
  print("  /tally research <itemlink-or-id> — print research record for an item")
  print("  /tally rescan — force inventory rescan via Syndicator")
  print("  /tally strategy — print current price strategy")
  print("  /tally strategy <expression> — set price strategy (any TSM-valid expression)")
end

local function handleSlash(msg)
  msg = (msg or ""):match("^%s*(.-)%s*$") -- trim
  if msg == "" or msg == "help" then
    printHelp()
    return
  end
  local cmd, rest = msg:match("^(%S+)%s*(.*)$")
  cmd = cmd:lower()
  if cmd == "networth" or cmd == "nw" then
    ns.NetWorth:Print()
  elseif cmd == "ownedworth" or cmd == "ow" then
    ns.NetWorth:Print({ includeBound = true })
  elseif cmd == "research" or cmd == "r" then
    if rest == "" then
      print("|cff7fbfffTally:|r usage — /tally research <itemlink-or-id>")
    else
      ns.Research:Print(rest)
    end
  elseif cmd == "rescan" then
    local ok, err = ns.Inventory:Rebuild()
    if ok then print("|cff7fbfffTally:|r inventory rescanned.")
    else print("|cffff4040Tally:|r rescan failed — " .. tostring(err)) end
  elseif cmd == "strategy" then
    if rest == "" then
      print("|cff7fbfffTally:|r price strategy = " .. ns.NetWorth:GetStrategy())
    else
      local ok, err = ns.NetWorth:SetStrategy(rest)
      if ok then print("|cff7fbfffTally:|r price strategy set to '" .. rest .. "'.")
      else print("|cffff4040Tally:|r " .. tostring(err)) end
    end
  else
    printHelp()
  end
end

SLASH_TALLY1 = "/tally"
SLASH_TALLY2 = "/tly"
SlashCmdList["TALLY"] = handleSlash

-- ============================================================================
-- LibDataBroker launcher + minimap icon
-- ============================================================================
local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
local LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)

if LDB then
  local dataobject = LDB:NewDataObject(addonName, {
    type = "data source",
    text = addonName,
    icon = "Interface\\AddOns\\Tally\\Art\\tl-inner",
    OnClick = function(_, button)
      if button == "LeftButton" then
        ns.NetWorth:Print()
      end
    end,
    OnTooltipShow = function(tooltip)
      local snap = ns.NetWorth:Snapshot()
      local owned = ns.NetWorth:Snapshot({ includeBound = true })
      tooltip:SetText("|cff7fbfffTally|r — net worth (saleable items only)")
      tooltip:AddLine(" ")
      tooltip:AddDoubleLine("Total", ns.NetWorth.FormatGold(snap.total), 1, 1, 1, 1, 1, 1)
      tooltip:AddDoubleLine("  Gold", ns.NetWorth.FormatGold(snap.gold), 0.7, 0.7, 0.7, 1, 1, 1)
      tooltip:AddDoubleLine("  Items", ns.NetWorth.FormatGold(snap.items), 0.7, 0.7, 0.7, 1, 1, 1)
      if snap.warband.total > 0 then
        tooltip:AddDoubleLine("Warband", ns.NetWorth.FormatGold(snap.warband.total), 0.7, 0.85, 1, 1, 1, 1)
      end
      tooltip:AddLine(" ")
      tooltip:AddDoubleLine("Owned worth (incl. bound)", ns.NetWorth.FormatGold(owned.total),
        0.6, 0.6, 0.6, 0.85, 0.85, 0.85)
      tooltip:AddLine(" ")
      tooltip:AddLine("Strategy: " .. snap.strategy, 0.6, 0.6, 0.6)
      tooltip:AddLine("Left-click: print details", 0.6, 0.6, 0.6)
    end,
  })

  -- Live-update LDB text with the running total. Throttled to event-driven
  -- updates from Cogworks; if Cogworks isn't available we update on demand only.
  local function refreshText()
    local snap = ns.NetWorth:Snapshot()
    dataobject.text = ns.NetWorth.FormatGold(snap.total)
  end
  refreshText()

  if Cogworks and Cogworks.RegisterCallback and Cogworks.Events then
    Cogworks.RegisterCallback(addonName, Cogworks.Events.InventoryChanged, refreshText)
  end

  -- Cogworks wraps LibDBIcon registration with the suite's gear-ring border
  -- so every cog's minimap button shares the Chronoforge silhouette. Falls
  -- back to a plain LDBIcon registration if Cogworks isn't loaded.
  if Cogworks and Cogworks.RegisterCogMinimapButton then
    Cogworks:RegisterCogMinimapButton(addonName, dataobject, TallyDB.minimap)
  elseif LDBIcon then
    LDBIcon:Register(addonName, dataobject, TallyDB.minimap)
  end
end
