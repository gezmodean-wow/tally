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
  -- Register UI pages with the main frame. Page bodies are lazy-created on
  -- first ShowPage so login cost is zero for users who never open the UI.
  if ns.UI and ns.UI.MainFrame then
    if ns.UI.CreateNetWorthPage then
      ns.UI.MainFrame:RegisterPage("Net Worth", ns.UI.CreateNetWorthPage)
    end
    if ns.UI.CreateResearchPage then
      ns.UI.MainFrame:RegisterPage("Research", ns.UI.CreateResearchPage)
    end
  end
  -- Invalidate research cache on inventory updates so consumers always see
  -- fresh ownership/valuation. Cogworks event bus is the broadcast channel.
  if Cogworks and Cogworks.RegisterCallback and Cogworks.Events then
    Cogworks.RegisterCallback(addonName, Cogworks.Events.InventoryChanged, function()
      if ns.Research then ns.Research:Invalidate() end
      -- First-of-session opportunity to take a price snapshot once Syndicator
      -- + TSM are loaded. History:MaybeSnapshot is gated on min-interval, so
      -- subsequent inventory churn won't spam snapshots.
      if ns.History then ns.History:MaybeSnapshot() end
      -- Refresh open UI so live values stay current.
      if ns.UI and ns.UI.MainFrame and ns.UI.MainFrame:IsShown() then
        local active = ns.UI.MainFrame:GetActivePage()
        if active then ns.UI.MainFrame:ShowPage(active) end
      end
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
  minor = 3,
  api = {
    GetItemResearch = function(input, itemName) return ns.Research:GetRecord(input, itemName) end,
    InvalidateItemResearch = function(itemKey) ns.Research:Invalidate(itemKey) end,
    GetNetWorthSnapshot = function(opts) return ns.NetWorth:Snapshot(opts) end,
    GetNetWorthSnapshotAt = function(atTime, opts) return ns.History:GetNetWorthAt(atTime, opts) end,
    GetInventoryRollup = function() return ns.Inventory:Get() end,
    GetItemPriceHistory = function(itemID, strategy) return ns.History:GetItemHistory(itemID, strategy) end,
    GetItemPriceTrend = function(itemID, windowSec, strategy) return ns.History:GetItemTrend(itemID, windowSec, strategy) end,
    GetItemInventoryHistory = function(itemID) return ns.History:GetItemInventoryHistory(itemID) end,
    GetItemInventoryTrend = function(itemID, windowSec) return ns.History:GetItemInventoryTrend(itemID, windowSec) end,
  },
}

-- ============================================================================
-- Slash commands
-- ============================================================================
local function printHelp()
  local prefix = "|cff7fbfffTally|r"
  print(prefix .. " — Personal Capital for WoW.")
  print("  /tally show — open the Tally main frame")
  print("  /tally networth (or /tly nw) — print current net worth (saleable items only)")
  print("  /tally networth at -<duration> — reconstruct net worth at a past time (e.g. -7d, -1h)")
  print("  /tally ownedworth (or /tly ow) — print owned worth (includes bound items)")
  print("  /tally ownedworth at -<duration> — historical owned-worth view")
  print("  /tally research <itemlink-or-id> — open the research panel for an item")
  print("  /tally research-chat <itemlink-or-id> (or /tly rc) — print research record to chat")
  print("  /tally rescan — force inventory rescan via Syndicator")
  print("  /tally strategy — print current price strategy")
  print("  /tally strategy <expression> — set price strategy (any TSM-valid expression)")
  print("  /tally history — show pricing-history summary and config")
  print("  /tally history snapshot — force a price snapshot now")
  print("  /tally history interval <hours> — set min hours between auto-snapshots (0 = disable)")
  print("  /tally history retention <days> — set max age of recorded snapshots")
  print("  /tally history rollup <days> — collapse snapshots older than this to one per day")
  print("  /tally history clear [strategy] — wipe history (all strategies, or one)")
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

-- Parse a relative-time expression into a positive seconds offset (always past).
-- Accepts forms like "-7d", "7d", "1h", "90m", "30s", "1w". Returns nil on bad input.
local function parsePastOffsetSec(text)
  if type(text) ~= "string" or text == "" then return nil end
  text = text:lower():gsub("%s+", "")
  local sign = "-"
  if text:sub(1, 1) == "-" or text:sub(1, 1) == "+" then
    sign = text:sub(1, 1); text = text:sub(2)
  end
  local n, unit = text:match("^(%d+)([dhmsw])$")
  if not n then return nil end
  n = tonumber(n)
  local mult = ({ s = 1, m = 60, h = 3600, d = 86400, w = 7 * 86400 })[unit]
  if not mult or sign == "+" then return nil end
  return n * mult
end

local function handleNetWorth(rest, includeBound)
  local err = "|cffff4040Tally:|r"
  rest = (rest or ""):match("^%s*(.-)%s*$")

  -- "at <duration>" → reconstruct historical snapshot.
  local atArg = rest:match("^at%s+(.+)$")
  if atArg then
    local offsetSec = parsePastOffsetSec(atArg)
    if not offsetSec then
      print(err .. " usage — /tally networth at -<duration> (e.g. -7d, -1h, -30m)")
      return
    end
    if not ns.History or not ns.History.GetNetWorthAt then
      print(err .. " history module unavailable")
      return
    end
    local atTime = time() - offsetSec
    local snap, info = ns.History:GetNetWorthAt(atTime, { includeBound = includeBound })
    if not snap then
      print(err .. " " .. tostring(info or "no historical data"))
      return
    end
    local label = string.format("(at %s, %s ago)",
      date("%Y-%m-%d %H:%M", snap.atTime), describeAge(offsetSec))
    ns.NetWorth:PrintSnapshot(snap, label)
    if info then print("  |cffffd070note:|r " .. info) end
    -- Δ vs current
    local current = ns.NetWorth:Snapshot({ includeBound = includeBound })
    local delta = current.total - snap.total
    local sign = delta >= 0 and "+" or "-"
    local pct = ""
    if snap.total > 0 then
      pct = string.format(" (%s%.1f%%)", delta >= 0 and "+" or "-", math.abs(delta / snap.total) * 100)
    end
    print(string.format("  Δ vs now: %s%s%s",
      sign, ns.NetWorth.FormatGold(math.abs(delta)), pct))
    return
  end

  if rest ~= "" then
    print(err .. " unknown net-worth subcommand. Try `/tally networth` or `/tally networth at -7d`.")
    return
  end

  ns.NetWorth:Print({ includeBound = includeBound })
end

local function handleHistory(args)
  local prefix = "|cff7fbfffTally|r"
  local err = "|cffff4040Tally:|r"
  local sub, rest = args:match("^(%S*)%s*(.*)$")
  sub = (sub or ""):lower()

  if sub == "" or sub == "config" then
    local cfg = ns.History:GetConfig()
    local summary = ns.History:GetSummary()
    local now = time()
    print(prefix .. " history:")
    print(string.format("  interval: %s (0 = disabled)", describeAge(cfg.minIntervalSec)))
    print(string.format("  retention: %s", describeAge(cfg.retentionSec)))
    print(string.format("  daily-rollup after: %s", describeAge(cfg.rollupAfterSec)))
    print("  pricing:")
    if #summary.pricing == 0 then
      print("    (no snapshots yet)")
    else
      for _, row in ipairs(summary.pricing) do
        local ageLast = row.lastSnapshotAt and (now - row.lastSnapshotAt) or nil
        local span = (row.lastSnapshotAt and row.oldestAt) and (row.lastSnapshotAt - row.oldestAt) or 0
        print(string.format("    [%s] %d snapshots, last %s ago, spanning %s",
          row.strategy, row.snapshotCount, describeAge(ageLast), describeAge(span)))
      end
    end
    local inv = summary.inventory
    if inv.snapshotCount == 0 then
      print("  inventory: (no snapshots yet)")
    else
      local ageLast = inv.lastSnapshotAt and (now - inv.lastSnapshotAt) or nil
      local span = (inv.lastSnapshotAt and inv.oldestAt) and (inv.lastSnapshotAt - inv.oldestAt) or 0
      print(string.format("  inventory: %d snapshots, last %s ago, spanning %s",
        inv.snapshotCount, describeAge(ageLast), describeAge(span)))
    end
    return
  end

  if sub == "snapshot" then
    local ok, info = ns.History:Snapshot({ force = true })
    if ok then
      print(string.format("%s snapshot recorded under %s — %d priced items, %d inventory items.",
        prefix, info.strategy, info.pricedItems, info.inventoryItems))
    else
      print(err .. " snapshot skipped — " .. tostring(info))
    end
    return
  end

  if sub == "interval" then
    local hours = tonumber(rest)
    if not hours or hours < 0 then
      print(err .. " usage — /tally history interval <hours> (0 disables auto-snapshot)")
      return
    end
    local ok, e = ns.History:SetInterval(hours * 3600)
    if ok then print(prefix .. " interval set to " .. hours .. "h.")
    else print(err .. " " .. tostring(e)) end
    return
  end

  if sub == "retention" then
    local days = tonumber(rest)
    if not days or days <= 0 then
      print(err .. " usage — /tally history retention <days>")
      return
    end
    local ok, e = ns.History:SetRetention(days * 86400)
    if ok then print(prefix .. " retention set to " .. days .. "d.")
    else print(err .. " " .. tostring(e)) end
    return
  end

  if sub == "rollup" then
    local days = tonumber(rest)
    if not days or days <= 0 then
      print(err .. " usage — /tally history rollup <days>")
      return
    end
    local ok, e = ns.History:SetRollupThreshold(days * 86400)
    if ok then print(prefix .. " daily-rollup threshold set to " .. days .. "d.")
    else print(err .. " " .. tostring(e)) end
    return
  end

  if sub == "clear" then
    local target = rest ~= "" and rest or nil
    ns.History:Clear(target)
    print(prefix .. " history cleared" .. (target and (" for " .. target) or "") .. ".")
    return
  end

  print(err .. " unknown history subcommand '" .. sub .. "'. Try /tally history.")
end

local function handleSlash(msg)
  msg = (msg or ""):match("^%s*(.-)%s*$") -- trim
  if msg == "" or msg == "help" then
    printHelp()
    return
  end
  local cmd, rest = msg:match("^(%S+)%s*(.*)$")
  cmd = cmd:lower()
  if cmd == "show" or cmd == "ui" then
    if ns.UI and ns.UI.MainFrame then
      ns.UI.MainFrame:Toggle()
    else
      print("|cffff4040Tally:|r UI module unavailable.")
    end
  elseif cmd == "networth" or cmd == "nw" then
    handleNetWorth(rest, false)
  elseif cmd == "ownedworth" or cmd == "ow" then
    handleNetWorth(rest, true)
  elseif cmd == "research" or cmd == "r" then
    if rest == "" then
      -- Open the Research panel without an item; user can type into the input.
      if ns.UI and ns.UI.ShowResearch then ns.UI.ShowResearch(nil)
      else print("|cff7fbfffTally:|r usage — /tally research <itemlink-or-id>") end
    else
      if ns.UI and ns.UI.ShowResearch then ns.UI.ShowResearch(rest)
      else ns.Research:Print(rest) end
    end
  elseif cmd == "research-chat" or cmd == "rc" then
    -- Preserved chat-only printout for power users / debugging.
    if rest == "" then
      print("|cff7fbfffTally:|r usage — /tally research-chat <itemlink-or-id>")
    else
      ns.Research:Print(rest)
    end
  elseif cmd == "rescan" then
    local ok, err = ns.Inventory:Rebuild()
    if ok then print("|cff7fbfffTally:|r inventory rescanned.")
    else print("|cffff4040Tally:|r rescan failed — " .. tostring(err)) end
  elseif cmd == "history" or cmd == "h" then
    handleHistory(rest)
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
        if ns.UI and ns.UI.MainFrame then
          ns.UI.MainFrame:Toggle()
        else
          ns.NetWorth:Print()
        end
      elseif button == "RightButton" then
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

      -- 7d / 30d delta lines, sourced from history. Suppress silently when
      -- the available snapshot is fresher than half the requested window —
      -- otherwise we'd be comparing "now" to "1h ago" and calling it Δ7d.
      local function deltaLine(label, windowSec)
        if not (ns.History and ns.History.GetNetWorthAt) then return end
        local past = ns.History:GetNetWorthAt(time() - windowSec)
        if not past then return end
        if (time() - past.atTime) < (windowSec * 0.5) then return end
        local delta = snap.total - past.total
        local sign = delta >= 0 and "+" or "-"
        local pctStr = ""
        if past.total > 0 then
          pctStr = string.format(" (%s%.1f%%)", sign, math.abs(delta / past.total) * 100)
        end
        local r, g, b
        local pctMag = past.total > 0 and math.abs(delta / past.total) * 100 or 0
        if pctMag < 0.5 then
          r, g, b = 0.7, 0.7, 0.7
        elseif delta >= 0 then
          r, g, b = 0.4, 1.0, 0.4
        else
          r, g, b = 1.0, 0.4, 0.4
        end
        tooltip:AddDoubleLine(label,
          sign .. ns.NetWorth.FormatGold(math.abs(delta)) .. pctStr,
          0.7, 0.7, 0.7, r, g, b)
      end
      deltaLine("  Δ 7d",  7  * 86400)
      deltaLine("  Δ 30d", 30 * 86400)

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

  if Cogworks and Cogworks.RegisterCogMinimapButton then
    Cogworks:RegisterCogMinimapButton(addonName, dataobject, TallyDB.minimap)
  elseif LDBIcon then
    LDBIcon:Register(addonName, dataobject, TallyDB.minimap)
  end
end
