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
    -- Register with the canonical capitalized name so the suite roster /
    -- gear assembly recognises Tally as installed. The folder name
    -- (`addonName` here) is "tally" lowercase and would miss the
    -- "Tally" entry in `lib.SuiteRoster`.
    Cogworks:RegisterAddon("Tally", {
      prefix  = "|cff8b5cf6[Tally]|r ",
      website = "https://github.com/gezmodean-wow/tally",
    })
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
  -- TLY-21: force a one-shot history prune on login so users coming from the
  -- pre-fix legacy defaults (365d retention) immediately reclaim memory once
  -- the migration in History.db() trims their config to 90d.
  if ns.History and ns.History.Prune then
    pcall(ns.History.Prune, ns.History)
  end
  if ns.Inventory and ns.Inventory.RegisterSyndicatorCallbacks then
    ns.Inventory:RegisterSyndicatorCallbacks()
  end
  -- Register ledger source adapters. Each adapter registers itself with
  -- ns.Ledger; we then run the available ones to backfill on login.
  if ns.Sources then
    if ns.Sources.Native      then ns.Sources.Native:Register()      end
    if ns.Sources.FlipQueue   then ns.Sources.FlipQueue:Register()   end
    if ns.Sources.TSM         then ns.Sources.TSM:Register()         end
    if ns.Sources.Journalator then ns.Sources.Journalator:Register() end
  end
  -- Pre-wizard upgrader grandfather: anyone who already has ledger entries
  -- (i.e., an existing Tally user installing this build) gets the setup
  -- flag flipped true so their imports keep flowing. Only fresh installs
  -- and post-`/tally reset` users go through the wizard gate.
  --
  -- The signal here is deliberately the ledger row count, not the
  -- inventory rollup. Inventory:Rebuild repopulates rollup the moment
  -- /tally reset finishes, so keying off that incorrectly identified a
  -- just-reset user on their next login as a returning upgrader and
  -- silently re-opened the gate. Ledger rows survive nothing except a
  -- legitimate prior Tally session.
  if TallyDB.ledger and TallyDB.ledger.entries and #TallyDB.ledger.entries > 0
     and not (TallyDB.setup and TallyDB.setup.completed) then
    TallyDB.setup = TallyDB.setup or {}
    TallyDB.setup.completed = true
    TallyDB.setup.grandfathered = true
    TallyDB.setup.completedAt = TallyDB.setup.completedAt or time()
  end

  -- TLY-21: defer the initial sibling-source backfill 5s after login so
  -- character-select / first-zone-load isn't fighting a multi-MB TSM CSV
  -- parse for the player's input thread. Native source is event-driven
  -- and doesn't need this timer.
  --
  -- TLY-25: gated on the setup-complete flag. Fresh installs and
  -- post-reset users see the wizard first; nothing flows into the
  -- ledger until they finish it.
  if ns.Ledger and ns.Ledger.ImportFromAllSources and C_Timer and C_Timer.After then
    C_Timer.After(5, function()
      if ns.Ledger:IsSetupComplete() then
        ns.Ledger:ImportFromAllSources()
      end
    end)
  end
  -- Register UI pages with the main frame. Page bodies are lazy-created on
  -- first ShowPage so login cost is zero for users who never open the UI.
  if ns.UI and ns.UI.MainFrame then
    if ns.UI.CreateNetWorthPage then
      ns.UI.MainFrame:RegisterPage("Net Worth", ns.UI.CreateNetWorthPage)
    end
    if ns.UI.CreateInventoryPage then
      ns.UI.MainFrame:RegisterPage("Inventory", ns.UI.CreateInventoryPage)
    end
    if ns.UI.CreateResearchPage then
      ns.UI.MainFrame:RegisterPage("Research", ns.UI.CreateResearchPage)
    end
    if ns.UI.CreateLifecyclePage then
      ns.UI.MainFrame:RegisterPage("Lifecycle", ns.UI.CreateLifecyclePage)
    end
    if ns.UI.CreateLedgerPage then
      ns.UI.MainFrame:RegisterPage("Ledger", ns.UI.CreateLedgerPage)
    end
    -- Compare tab is gated by a Settings toggle; default off so non-debug
    -- users don't see it. Read TallyDB directly to avoid an order
    -- dependency between this block and the Settings panel.
    TallyDB.ui = TallyDB.ui or {}
    if TallyDB.ui.showCompareTab and ns.UI.CreateCompareLedgersPage then
      ns.UI.MainFrame:RegisterPage("Compare", ns.UI.CreateCompareLedgersPage)
    end
    if ns.UI.CreateSettingsPage then
      ns.UI.MainFrame:RegisterPage("Settings", ns.UI.CreateSettingsPage)
    end
  end

  -- TLY-25: auto-show the setup wizard for fresh installs with detected
  -- sibling sources. Deferred 6s after login (1s past the source-import
  -- defer) so source registration + availability checks have settled.
  if C_Timer and C_Timer.After and ns.UI and ns.UI.ShouldShowSetupWizard then
    C_Timer.After(6, function()
      if ns.UI.ShouldShowSetupWizard() then
        if ns.UI.ShowSetupWizard then ns.UI.ShowSetupWizard() end
      end
    end)
  end
  -- Invalidate research cache on inventory updates so consumers always see
  -- fresh ownership/valuation. Cogworks event bus is the broadcast channel.
  --
  -- Performance note (TLY-21): InventoryChanged fires for every Syndicator
  -- cache event — every bag slot change, every auction posted, every mail
  -- received. We deliberately do NOT re-import sibling-addon ledgers here:
  -- TSM CSVs and FlipQueue logs are megabytes of data, parsing them on every
  -- bag-slot change burns frames and grows the ledger unboundedly. Source
  -- adapters re-run only at PLAYER_LOGIN, on user-pressed "Import now" in
  -- the Settings panel, or on a long-period timer.
  if Cogworks and Cogworks.RegisterCallback and Cogworks.Events then
    Cogworks.RegisterCallback(addonName, Cogworks.Events.InventoryChanged, function()
      if ns.Research then ns.Research:Invalidate() end
      -- History:MaybeSnapshot is gated on min-interval (default 6h), so
      -- this is cheap unless a snapshot is genuinely due.
      if ns.History then ns.History:MaybeSnapshot() end
      -- Refresh open UI so live values stay current.
      if ns.UI and ns.UI.MainFrame and ns.UI.MainFrame:IsShown() then
        ns.UI.MainFrame:RefreshActivePage()
      end
    end)
  end

  -- Periodic ledger backfill from sibling-addon adapters. 5-minute timer is
  -- well below the cadence at which TSM Accounting / FlipQueue write new
  -- rows, while staying far away from the per-bag-event hot path. Native
  -- source is event-driven (MAIL_INBOX_UPDATE) so it never relies on this.
  -- TLY-25: gated on setup-complete; the ticker keeps running but each
  -- tick is a no-op until the wizard finishes.
  if ns.Ledger and ns.Ledger.ImportFromAllSources and C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(300, function()
      if ns.Ledger:IsSetupComplete() then
        ns.Ledger:ImportFromAllSources()
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
  minor = 5,
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
    QueryLedger = function(filter) return ns.Ledger:Query(filter) end,
    LedgerStats = function(filter) return ns.Ledger:Stats(filter) end,
    -- v1.5 (TLY-26 / TLY-27)
    GetItemLifecycle = function(itemID, opts) return ns.Lifecycle and ns.Lifecycle:GetRecord(itemID, opts) or nil end,
    CompareLedgerSources = function(a, b, filter) return ns.Ledger:Compare(a, b, filter) end,
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
  print("  /tally reset confirm — wipe ledger + history + inventory rollup, then re-init")
  print("  /tally setup — re-run the first-time setup wizard")
  print("  /tally lifecycle <itemlink-or-id> — open per-item lifecycle drill-down")
  print("  /tally compare — open the multi-source ledger comparison view")
  print("  /tally inventory [charKey] — open the per-character inventory drill-down")
end

-- Wipes the data stores Tally accumulates at runtime — ledger, history,
-- inventory rollup, the setup-completed flag, and any user source opt-outs
-- — then re-runs the inventory scan and re-shows the setup wizard so the
-- user lands back in the first-run flow. Config that doesn't represent
-- accumulated data is preserved (strategy, history cadence, minimap, UI
-- position).
--
-- The wizard handles the chunked backfill from sibling sources — reset
-- intentionally does NOT auto-import. Otherwise we'd race the wizard's
-- own backfill on Finish and double-insert / starve the user's input
-- thread before they've even picked a pace.
local function resetData()
  local prefix = "|cff7fbfffTally|r"
  if ns.Ledger and ns.Ledger.Clear then ns.Ledger:Clear() end
  if ns.History and ns.History.Clear then ns.History:Clear() end
  TallyDB.inventoryRollup = nil
  TallyDB.setup = nil          -- clear completed flag so wizard re-fires
  TallyDB.disabledSources = nil -- re-let the user pick sources in the wizard

  print(prefix .. " data cleared (ledger, history, inventory rollup, setup state). Rebuilding inventory…")

  if ns.Inventory and ns.Inventory.Rebuild then
    ns.Inventory:Rebuild()
  end

  -- Hand off to the setup wizard. Defer slightly so the rebuild broadcast
  -- + UI close races settle. The wizard's own onComplete drives the
  -- chunked sibling-source backfill via Ledger:ImportFromAllSourcesChunked.
  if C_Timer and C_Timer.After then
    C_Timer.After(0.5, function()
      -- Close the main frame if it's open (likely is — user clicked the
      -- reset button from Settings) so the wizard isn't competing with it
      -- for screen real estate.
      if ns.UI and ns.UI.MainFrame and ns.UI.MainFrame.IsShown
         and ns.UI.MainFrame:IsShown() then
        ns.UI.MainFrame:Hide()
      end
      -- Blow away the existing wizard singleton so the rebuild starts
      -- from a clean state — fresh source-enable checkboxes, fresh
      -- strategy radio, fresh pace selection. Without this the user
      -- lands on whatever they had selected last run.
      if ns.UI and ns.UI.ResetSetupWizard then ns.UI.ResetSetupWizard() end
      if ns.RefreshLDB then pcall(ns.RefreshLDB) end
      if ns.UI and ns.UI.ShowSetupWizard then
        ns.UI.ShowSetupWizard()
        print(prefix .. " setup wizard reopened — your data will be re-imported when you finish it.")
      else
        -- Wizard unavailable (no Cogworks v0.11.0?). Fall back to the old
        -- behaviour: synchronous slurp. Better than leaving the user with
        -- an empty ledger.
        print(prefix .. " setup wizard unavailable; running synchronous backfill instead.")
        if ns.Ledger and ns.Ledger.ImportFromAllSources then
          local results = ns.Ledger:ImportFromAllSources()
          local total = 0
          for _, r in ipairs(results) do total = total + (r.inserted or 0) end
          print(string.format("%s reset complete — %d ledger entries re-imported.", prefix, total))
        end
      end
    end)
  end
end

ns.Reset = resetData

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
  elseif cmd == "reset" then
    if rest == "confirm" then
      resetData()
    else
      print("|cffff4040Tally:|r `/tally reset confirm` will wipe ledger, history, and inventory rollup.")
      print("|cffff4040Tally:|r Config (strategy, history cadence, minimap, UI prefs) is preserved. Sibling-source import re-runs after.")
    end
  elseif cmd == "setup" or cmd == "wizard" then
    if ns.UI and ns.UI.ShowSetupWizard then
      ns.UI.ShowSetupWizard()
    else
      print("|cffff4040Tally:|r setup wizard unavailable.")
    end
  elseif cmd == "lifecycle" or cmd == "lc" then
    if ns.UI and ns.UI.ShowLifecycle then
      ns.UI.ShowLifecycle(rest)
    else
      print("|cffff4040Tally:|r lifecycle UI unavailable.")
    end
  elseif cmd == "inventory" or cmd == "inv" then
    if ns.UI and ns.UI.ShowInventory then
      ns.UI.ShowInventory(rest ~= "" and rest or nil)
    else
      print("|cffff4040Tally:|r inventory page unavailable.")
    end
  elseif cmd == "compare" then
    if ns.UI and ns.UI.MainFrame and ns.UI.CreateCompareLedgersPage then
      -- If the Compare tab isn't currently registered (toggle off), turn
      -- it on for this session so the slash command works regardless.
      TallyDB.ui = TallyDB.ui or {}
      if not TallyDB.ui.showCompareTab then
        TallyDB.ui.showCompareTab = true
        ns.UI.MainFrame:RegisterPage("Compare", ns.UI.CreateCompareLedgersPage)
      end
      ns.UI.MainFrame:Show()
      ns.UI.MainFrame:ShowPage("Compare")
    else
      print("|cffff4040Tally:|r compare view unavailable.")
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
  -- Pre-setup tooltip + click behavior. Until the user finishes the wizard,
  -- the icon makes that crystal clear instead of pretending to show a
  -- (mostly-empty) net worth tooltip.
  local function setupPending()
    return ns.Ledger and ns.Ledger.IsSetupComplete and not ns.Ledger:IsSetupComplete()
  end

  local dataobject = LDB:NewDataObject(addonName, {
    type = "data source",
    text = addonName,
    icon = "Interface\\AddOns\\Tally\\Art\\tl-inner",
    OnClick = function(_, button)
      -- Pre-setup: any click launches the wizard. Net worth doesn't mean
      -- anything yet so right-click's chat printout would be noise.
      if setupPending() then
        if ns.UI and ns.UI.ShowSetupWizard then ns.UI.ShowSetupWizard() end
        return
      end
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
      -- Pre-setup: dedicated "setup required" tooltip. Hides the
      -- regular net worth breakdown until imports have actually run,
      -- so the user doesn't see "Total: 0g" and assume Tally is broken.
      if setupPending() then
        tooltip:SetText("|cffffd070Tally|r — setup required")
        tooltip:AddLine(" ")
        tooltip:AddLine("Tally hasn't run its first-time setup yet.", 1, 1, 1, true)
        tooltip:AddLine("Nothing has been imported from TSM, FlipQueue,", 0.85, 0.85, 0.85, true)
        tooltip:AddLine("Journalator, or your mailbox until you finish", 0.85, 0.85, 0.85, true)
        tooltip:AddLine("the wizard.", 0.85, 0.85, 0.85, true)
        tooltip:AddLine(" ")
        local detected = {}
        if ns.Ledger and ns.Ledger.GetSources then
          for _, s in ipairs(ns.Ledger:GetSources()) do
            if s.name ~= "tally-native" and ns.Ledger:IsSourceAvailable(s.name) then
              detected[#detected + 1] = s.label
            end
          end
        end
        if #detected > 0 then
          tooltip:AddLine("Sources detected: " .. table.concat(detected, ", "),
            0.6, 0.85, 0.6, true)
        else
          tooltip:AddLine("No sibling sources detected — Tally will run on",
            0.85, 0.7, 0.5, true)
          tooltip:AddLine("native event capture only.", 0.85, 0.7, 0.5, true)
        end
        tooltip:AddLine(" ")
        tooltip:AddLine("Click to start setup.", 1, 0.82, 0, true)
        return
      end

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
      tooltip:AddLine("Left-click: open Tally  •  Right-click: print summary", 0.6, 0.6, 0.6)
    end,
  })

  -- Live-update LDB text with the running total. Throttled to event-driven
  -- updates from Cogworks; if Cogworks isn't available we update on demand only.
  -- Pre-setup we surface "setup required" instead of "0g" so the launcher
  -- text itself is unambiguous.
  local function refreshText()
    if setupPending() then
      dataobject.text = "|cffffd070setup required|r"
      return
    end
    local snap = ns.NetWorth:Snapshot()
    dataobject.text = ns.NetWorth.FormatGold(snap.total)
  end
  refreshText()
  ns.RefreshLDB = refreshText  -- exposed so the wizard can re-skin the
                                 -- launcher the moment setup completes

  if Cogworks and Cogworks.RegisterCallback and Cogworks.Events then
    Cogworks.RegisterCallback(addonName, Cogworks.Events.InventoryChanged, refreshText)
  end

  if Cogworks and Cogworks.RegisterCogMinimapButton then
    Cogworks:RegisterCogMinimapButton(addonName, dataobject, TallyDB.minimap)
  elseif LDBIcon then
    LDBIcon:Register(addonName, dataobject, TallyDB.minimap)
  end
end
