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

-- Per-cog debug logger. Cogworks v0.13's debug toolkit gives us a ring
-- buffer + chat echo gated by an enabled flag, plus the live console at
-- `/tally debug`. Modules call `ns.dbg:PrintDebug(...)` to trace event
-- flow during testing; in production the enabled flag stays false and
-- the calls are essentially no-ops (the ring buffer captures them but
-- nothing reaches chat).
TallyDB = TallyDB or {}
if Cogworks and Cogworks.RegisterDebugLogger then
  ns.dbg = Cogworks:RegisterDebugLogger("Tally", {
    enabled = TallyDB.debug and true or false,
  })
end

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

  -- TLY-40 migration: pre-fix rollups (warband.items without bankItems /
  -- spillsByChar) may carry inflated counts from the old duplication bug.
  -- Ownership:Get already triggers a Rebuild when it sees the legacy shape,
  -- but only on first call — and that first call may happen before
  -- Syndicator's API is populated, so the Rebuild bails and the user sees
  -- stale data until they manually `/tally rescan`. Force a deferred
  -- Rebuild here so the migration completes without manual intervention.
  if TallyDB.inventoryRollup and TallyDB.inventoryRollup.warband
     and not TallyDB.inventoryRollup.warband.bankItems
     and ns.Inventory and ns.Inventory.Rebuild
     and C_Timer and C_Timer.After then
    C_Timer.After(5, function()
      ns.Inventory:Rebuild()
    end)
  end
  -- Register diagnostic inspectors with Cogworks's debug toolkit so the
  -- dev console + DumpDebugState read the same per-section state that
  -- /tally diag prints to chat.
  if ns.RegisterDiagInspectors then ns.RegisterDiagInspectors() end

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
-- The actual SLASH_<X>1 / SlashCmdList wiring + auto-help rendering happens
-- via cw:RegisterSlashCommands at the bottom of this file. Per-command run
-- handlers are defined inline there; the multi-line helpers below
-- (handleNetWorth, handleHistory, resetData) stay here because they're
-- substantial and benefit from named scope.

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

-- ============================================================================
-- /tally diag — one-shot diagnostic dump
-- ============================================================================
--
-- Each diagnostic section is an inspector function returning a Lua value
-- (table / string / nil). They're registered with Cogworks's debug toolkit
-- so the dev console (`/tally debug`) and `cw:DumpDebugState("Tally")` can
-- read them too — `/tally diag` is the chat-friendly dump that walks the
-- same inspectors and pretty-prints the result. Single source of truth for
-- the diagnostic surface.

local function describeBoolean(v)
  if v == nil then return "nil"
  elseif v then return "yes"
  else return "no" end
end

local function describeAgeAgo(seconds)
  if not seconds or seconds <= 0 then return "—" end
  local d = math.floor(seconds / 86400)
  if d > 0 then return d .. "d ago" end
  local h = math.floor(seconds / 3600)
  if h > 0 then return h .. "h ago" end
  local m = math.floor(seconds / 60)
  if m > 0 then return m .. "m ago" end
  return seconds .. "s ago"
end

-- Inspector functions. Pure of side effects — call them anywhere, anytime.

local function inspectVersions()
  local tocVer = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("Tally", "Version"))
              or (GetAddOnMetadata and GetAddOnMetadata("Tally", "Version"))
              or "?"
  local cw = LibStub and LibStub("Cogworks-1.0", true) or nil
  return {
    tally     = tostring(tocVer),
    cogworks  = (cw and cw.version) or "(not loaded)",
    interface = tostring(select(4, GetBuildInfo())),
  }
end

local function inspectSetup()
  return {
    completed     = TallyDB and TallyDB.setup and TallyDB.setup.completed and true or false,
    grandfathered = TallyDB and TallyDB.setup and TallyDB.setup.grandfathered and true or false,
    skipped       = TallyDB and TallyDB.setup and TallyDB.setup.skipped and true or false,
  }
end

local function inspectSyndicator()
  local available = type(_G.Syndicator) == "table" and type(_G.Syndicator.API) == "table"
  local out = {
    loaded              = available,
    hasGetAllCharacters = available and type(_G.Syndicator.API.GetAllCharacters) == "function" or false,
  }
  if available and _G.Syndicator.API.GetAllCharacters then
    local ok, chars = pcall(_G.Syndicator.API.GetAllCharacters)
    if ok and type(chars) == "table" then
      out.characters     = chars
      out.characterCount = #chars
    else
      out.characterError = tostring(chars)
    end
  end
  return out
end

local function inspectInventory()
  local now = time()
  local rollup = TallyDB and TallyDB.inventoryRollup
  if not rollup then return { missing = true } end
  local charCount, totalItems = 0, 0
  local emptyChars = {}
  for ck, char in pairs(rollup.characters or {}) do
    charCount = charCount + 1
    local n = 0
    for _ in pairs(char.items or {}) do n = n + 1 end
    totalItems = totalItems + n
    if n == 0 then emptyChars[#emptyChars + 1] = ck end
  end
  local out = {
    charCount     = charCount,
    distinctItems = totalItems,
    lastScanAge   = rollup.lastFullScan and (now - rollup.lastFullScan) or nil,
    emptyChars    = emptyChars,
  }
  if rollup.warband then
    local wbItems = 0
    for _ in pairs(rollup.warband.items or {}) do wbItems = wbItems + 1 end
    out.warband = {
      gold          = rollup.warband.gold or 0,
      distinctItems = wbItems,
    }
  end
  return out
end

-- Probes the raw Syndicator field names (TLY-24 — Toeknee's wrong warband /
-- per-char gold report). If Syndicator returns gold under a different key
-- than `.money`, this surfaces nil for the field we read versus a number
-- for one of the alternates, telling us exactly what to fix.
local function inspectCurrentChar()
  local me = (UnitName and UnitName("player") or "?") .. "-" .. (GetRealmName and GetRealmName() or "?")
  local out = { charKey = me }
  local available = type(_G.Syndicator) == "table" and type(_G.Syndicator.API) == "table"
  if available and _G.Syndicator.API.GetByCharacterFullName then
    local ok, data = pcall(_G.Syndicator.API.GetByCharacterFullName, me)
    if ok and type(data) == "table" then
      out.seenBySyndicator    = true
      out.syndicatorGoldFields = {
        money  = data.money,
        gold   = data.gold,
        copper = data.copper,
      }
    else
      out.seenBySyndicator = false
    end
  end
  local rollup = TallyDB and TallyDB.inventoryRollup
  if rollup and rollup.characters then
    local entry = rollup.characters[me]
    out.inRollup = entry ~= nil
    if entry then
      local n = 0
      for _ in pairs(entry.items or {}) do n = n + 1 end
      out.rollupItems = n
      out.rollupGold  = entry.gold or 0
    end
  end
  return out
end

local function inspectWarbandProbe()
  local available = type(_G.Syndicator) == "table" and type(_G.Syndicator.API) == "table"
  if not (available and _G.Syndicator.API.GetWarband) then return nil end
  local ok, wb = pcall(_G.Syndicator.API.GetWarband, 1)
  if ok and type(wb) == "table" then
    return { money = wb.money, gold = wb.gold, copper = wb.copper }
  end
  return { error = tostring(wb) }
end

local function inspectLedger()
  if not (ns.Ledger and ns.Ledger.Stats) then return nil end
  local stats = ns.Ledger:Stats({})
  return { rowCount = stats.count, bySource = stats.bySource }
end

-- Per-source skip counters (TLY-29 capture-layer rigor). Each adapter
-- registers a `skipCounters` table on its module and increments named
-- reasons at every early-return. Surfaces silent data loss.
local function inspectSkipCounters()
  local out = {}
  local function dump(label, mod)
    if type(mod) ~= "table" or type(mod.skipCounters) ~= "table" then return end
    local total = 0
    local reasons = {}
    for reason, n in pairs(mod.skipCounters) do
      if n > 0 then
        total = total + n
        reasons[reason] = n
      end
    end
    if total > 0 then out[label] = { total = total, reasons = reasons } end
  end
  if ns.Sources then
    dump("TSM",         ns.Sources.TSM)
    dump("FlipQueue",   ns.Sources.FlipQueue)
    dump("Journalator", ns.Sources.Journalator)
    dump("Native",      ns.Sources.Native)
  end
  return out
end

local function inspectHistory()
  if not (ns.History and ns.History.GetSummary) then return nil end
  local sum = ns.History:GetSummary()
  local out = { inventorySnapshots = sum.inventory.snapshotCount or 0, pricing = {} }
  for _, p in ipairs(sum.pricing or {}) do
    out.pricing[#out.pricing + 1] = { strategy = p.strategy, snapshots = p.snapshotCount }
  end
  return out
end

local function inspectDisabledSources()
  if not (TallyDB.disabledSources and next(TallyDB.disabledSources)) then return nil end
  local out = {}
  for name in pairs(TallyDB.disabledSources) do out[#out + 1] = name end
  table.sort(out)
  return out
end

local function inspectSiblings()
  return {
    TSM         = type(_G.TSM_API) == "table",
    FlipQueue   = type(_G.FlipQueueDB) == "table",
    Journalator = type(_G.JOURNALATOR_ARCHIVE_TIMES) == "table",
    Auctionator = type(_G.AUCTIONATOR_SHOPPING_LISTS) == "table" or type(_G.Auctionator) == "table",
  }
end

local function inspectMemory()
  if not (UpdateAddOnMemoryUsage and GetAddOnMemoryUsage) then return nil end
  UpdateAddOnMemoryUsage()
  return { kb = GetAddOnMemoryUsage("Tally") or 0 }
end

local DIAG_INSPECTORS = {
  { name = "Versions",        fn = inspectVersions },
  { name = "Setup",           fn = inspectSetup },
  { name = "Syndicator",      fn = inspectSyndicator },
  { name = "Inventory",       fn = inspectInventory },
  { name = "CurrentChar",     fn = inspectCurrentChar },
  { name = "WarbandProbe",    fn = inspectWarbandProbe },
  { name = "Ledger",          fn = inspectLedger },
  { name = "SkipCounters",    fn = inspectSkipCounters },
  { name = "History",         fn = inspectHistory },
  { name = "DisabledSources", fn = inspectDisabledSources },
  { name = "Siblings",        fn = inspectSiblings },
  { name = "Memory",          fn = inspectMemory },
}

-- Cogworks `RegisterDebugInspector` appends without dedupe — call once.
local diagInspectorsRegistered = false
local function registerDiagInspectors()
  if diagInspectorsRegistered then return end
  if not (Cogworks and Cogworks.RegisterDebugInspector) then return end
  for _, ins in ipairs(DIAG_INSPECTORS) do
    Cogworks:RegisterDebugInspector("Tally", ins.name, ins.fn)
  end
  diagInspectorsRegistered = true
end

-- Chat-friendly formatted dump. Walks each inspector and pretty-prints its
-- output with colors / human-friendly sizes. Same data as DumpDebugState,
-- shaped for inline reading + paste-into-issue.
local function diagPrintChat()
  print("|cff7fbfff== Tally diagnostic ==|r")
  print("|cff999999(copy these lines into a GitHub issue if you're reporting a bug)|r")

  local v = inspectVersions()
  print(string.format("Tally: %s  |  Cogworks: %s  |  Interface: %s",
    v.tally, v.cogworks, v.interface))

  local s = inspectSetup()
  print(string.format("Setup: completed=%s  grandfathered=%s",
    describeBoolean(s.completed), describeBoolean(s.grandfathered)))

  local syn = inspectSyndicator()
  print(string.format("Syndicator: loaded=%s  API.GetAllCharacters=%s",
    describeBoolean(syn.loaded), describeBoolean(syn.hasGetAllCharacters)))
  if syn.characters then
    print(string.format("  Syndicator chars (%d):", syn.characterCount))
    for i, ck in ipairs(syn.characters) do
      if i > 10 then
        print(string.format("    … and %d more", syn.characterCount - 10))
        break
      end
      print("    - " .. tostring(ck))
    end
  elseif syn.characterError then
    print("  Syndicator GetAllCharacters() failed: " .. syn.characterError)
  end

  local inv = inspectInventory()
  if inv.missing then
    print("Inventory rollup: |cffff8080missing|r — never built. Try /tally rescan.")
  else
    print(string.format("Inventory rollup: %d chars, %d distinct items, last scan %s",
      inv.charCount, inv.distinctItems, describeAgeAgo(inv.lastScanAge)))
    if inv.warband then
      print(string.format("  Warband: gold=%s, distinct items=%d",
        ns.NetWorth.FormatGold(inv.warband.gold), inv.warband.distinctItems))
    end
    if #inv.emptyChars > 0 then
      print("  |cffffd070Chars with 0 items in rollup:|r " ..
        table.concat(inv.emptyChars, ", "))
    end
  end

  local cur = inspectCurrentChar()
  if cur.seenBySyndicator ~= nil then
    print(string.format("Current char (%s): seen by Syndicator=%s",
      cur.charKey, describeBoolean(cur.seenBySyndicator)))
  end
  if cur.syndicatorGoldFields then
    print(string.format("  Syndicator gold fields: money=%s gold=%s copper=%s",
      tostring(cur.syndicatorGoldFields.money),
      tostring(cur.syndicatorGoldFields.gold),
      tostring(cur.syndicatorGoldFields.copper)))
  end
  if cur.inRollup ~= nil then
    print(string.format("  In rollup: %s (%d distinct items, gold=%s)",
      cur.inRollup and "yes" or "|cffff8080NO|r",
      cur.rollupItems or 0,
      cur.rollupGold and ns.NetWorth.FormatGold(cur.rollupGold) or "—"))
  end

  local wb = inspectWarbandProbe()
  if wb then
    if wb.error then
      print("Warband: GetWarband(1) returned " .. wb.error)
    else
      print(string.format("Warband (idx=1): money=%s gold=%s copper=%s",
        tostring(wb.money), tostring(wb.gold), tostring(wb.copper)))
    end
  end

  local lg = inspectLedger()
  if lg then
    print(string.format("Ledger: %d rows", lg.rowCount))
    if next(lg.bySource or {}) then
      for src, n in pairs(lg.bySource) do
        print(string.format("  %s: %d", src, n))
      end
    end
  end

  local sk = inspectSkipCounters()
  if sk and next(sk) then
    local labels = {}
    for k in pairs(sk) do labels[#labels + 1] = k end
    table.sort(labels)
    for _, label in ipairs(labels) do
      local entry = sk[label]
      print(string.format("  %s skipped %d rows since last load:", label, entry.total))
      local rs = {}
      for r, n in pairs(entry.reasons) do rs[#rs + 1] = string.format("    %s: %d", r, n) end
      table.sort(rs)
      for _, line in ipairs(rs) do print(line) end
    end
  end

  local h = inspectHistory()
  if h then
    print(string.format("History inventory: %d snapshots", h.inventorySnapshots))
    for _, p in ipairs(h.pricing) do
      print(string.format("  Pricing [%s]: %d snapshots", p.strategy, p.snapshots))
    end
  end

  local ds = inspectDisabledSources()
  if ds then
    print("Disabled sources: " .. table.concat(ds, ", "))
  end

  local sib = inspectSiblings()
  local sibOrder = { "TSM", "FlipQueue", "Journalator", "Auctionator" }
  local sibLine = "Siblings: "
  for i, name in ipairs(sibOrder) do
    if i > 1 then sibLine = sibLine .. "  " end
    sibLine = sibLine .. name .. "=" .. (sib[name] and "|cff7fffaeyes|r" or "|cff888888no|r")
  end
  print(sibLine)

  local m = inspectMemory()
  if m then
    print(string.format("Memory: %.1f KB", m.kb))
  end

  print("|cff7fbfff== end diagnostic ==|r")
end

-- Paste-friendly variant: opens Cogworks's CreateCopyDialog with the
-- DumpDebugState output (Lua-table format, structured, easy to diff
-- between testers). Falls back to chat dump if Cogworks debug toolkit
-- is unavailable for any reason.
local function diagOpenCopyDialog()
  if not (Cogworks and Cogworks.DumpDebugState and Cogworks.CreateCopyDialog) then
    diagPrintChat()
    return
  end
  registerDiagInspectors()
  local dump = Cogworks:DumpDebugState("Tally")
  Cogworks:CreateCopyDialog(dump, "Paste this into a GitHub issue when reporting a bug.")
end

-- Sibling cogs hold a reference to ns.Diag — preserve the contract.
ns.Diag = diagPrintChat
ns.DiagCopyDialog = diagOpenCopyDialog
ns.RegisterDiagInspectors = registerDiagInspectors

-- Live debug console — opens Cogworks's CreateDebugConsole({ cog = "Tally" }).
-- Singleton: one console instance reused across slash invocations. Position,
-- size, and pinned state persist into TallyDB.ui.debugConsole.
local debugConsole
local function toggleDebugConsole()
  if not (Cogworks and Cogworks.CreateDebugConsole) then
    print("|cffff4040Tally:|r debug console requires Cogworks v0.13+. Update Cogworks-1.0.")
    return
  end
  registerDiagInspectors()
  if not debugConsole then
    TallyDB.ui = TallyDB.ui or {}
    TallyDB.ui.debugConsole = TallyDB.ui.debugConsole or {}
    debugConsole = Cogworks:CreateDebugConsole({
      cog       = "Tally",
      savedvars = TallyDB.ui.debugConsole,
    })
  end
  if debugConsole:IsShown() then debugConsole:Hide() else debugConsole:Show() end
end

ns.ToggleDebugConsole = toggleDebugConsole

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

if Cogworks and Cogworks.RegisterSlashCommands then
  Cogworks:RegisterSlashCommands("Tally", {
    globals   = { "/tally", "/tly" },
    helpStyle = "chat",
    commands = {
      {
        name = "show", aliases = { "ui" },
        help = "Open the Tally main frame",
        run = function()
          if ns.UI and ns.UI.MainFrame then ns.UI.MainFrame:Toggle()
          else print("|cffff4040Tally:|r UI module unavailable.") end
        end,
      },
      {
        name = "networth", aliases = { "nw" },
        args = "[at -<duration>]",
        help = "Print current net worth (saleable items only)",
        run = function(rest) handleNetWorth(rest, false) end,
      },
      {
        name = "ownedworth", aliases = { "ow" },
        args = "[at -<duration>]",
        help = "Print owned worth (includes bound items)",
        run = function(rest) handleNetWorth(rest, true) end,
      },
      {
        name = "research", aliases = { "r" },
        args = "<itemlink-or-id>",
        help = "Open the research panel for an item",
        run = function(rest)
          if rest == "" then
            if ns.UI and ns.UI.ShowResearch then ns.UI.ShowResearch(nil)
            else print("|cff7fbfffTally:|r usage — /tally research <itemlink-or-id>") end
          else
            if ns.UI and ns.UI.ShowResearch then ns.UI.ShowResearch(rest)
            else ns.Research:Print(rest) end
          end
        end,
      },
      {
        name = "research-chat", aliases = { "rc" },
        args = "<itemlink-or-id>",
        help = "Print research record to chat (power-user / debug)",
        run = function(rest)
          if rest == "" then
            print("|cff7fbfffTally:|r usage — /tally research-chat <itemlink-or-id>")
          else
            ns.Research:Print(rest)
          end
        end,
      },
      {
        name = "rescan",
        help = "Force inventory rescan via Syndicator",
        run = function()
          local ok, err = ns.Inventory:Rebuild()
          if ok then print("|cff7fbfffTally:|r inventory rescanned.")
          else print("|cffff4040Tally:|r rescan failed — " .. tostring(err)) end
        end,
      },
      {
        name = "history", aliases = { "h" },
        args = "[snapshot|interval|retention|rollup|clear]",
        help = "Show pricing-history config / take snapshot / set retention",
        run = function(rest) handleHistory(rest) end,
      },
      {
        name = "strategy",
        args = "[<expression>]",
        help = "Print or set price strategy",
        run = function(rest)
          rest = rest or ""
          if rest == "" then
            print("|cff7fbfffTally:|r price strategy = " .. ns.NetWorth:GetStrategy())
          else
            local ok, err = ns.NetWorth:SetStrategy(rest)
            if ok then print("|cff7fbfffTally:|r price strategy set to '" .. rest .. "'.")
            else print("|cffff4040Tally:|r " .. tostring(err)) end
          end
        end,
      },
      {
        name = "reset",
        args = "confirm",
        help = "Wipe ledger + history + inventory rollup, then re-init",
        run = function(rest)
          if rest == "confirm" then
            resetData()
          else
            print("|cffff4040Tally:|r `/tally reset confirm` will wipe ledger, history, and inventory rollup.")
            print("|cffff4040Tally:|r Config (strategy, history cadence, minimap, UI prefs) is preserved. Sibling-source import re-runs after.")
          end
        end,
      },
      {
        name = "setup", aliases = { "wizard" },
        help = "Re-run the first-time setup wizard",
        run = function()
          if ns.UI and ns.UI.ShowSetupWizard then ns.UI.ShowSetupWizard()
          else print("|cffff4040Tally:|r setup wizard unavailable.") end
        end,
      },
      {
        name = "lifecycle", aliases = { "lc" },
        args = "<itemlink-or-id>",
        help = "Open per-item lifecycle drill-down",
        run = function(rest)
          if ns.UI and ns.UI.ShowLifecycle then ns.UI.ShowLifecycle(rest)
          else print("|cffff4040Tally:|r lifecycle UI unavailable.") end
        end,
      },
      {
        name = "inventory", aliases = { "inv" },
        args = "[charKey]",
        help = "Open the per-character inventory drill-down",
        run = function(rest)
          if ns.UI and ns.UI.ShowInventory then
            ns.UI.ShowInventory((rest and rest ~= "") and rest or nil)
          else
            print("|cffff4040Tally:|r inventory page unavailable.")
          end
        end,
      },
      {
        name = "compare",
        help = "Open the multi-source ledger comparison view",
        run = function()
          if ns.UI and ns.UI.MainFrame and ns.UI.CreateCompareLedgersPage then
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
        end,
      },
      {
        name = "diag", aliases = { "diagnostic" },
        args = "[copy]",
        help = "Print diagnostic dump (or open the structured copy dialog)",
        run = function(rest)
          if rest and rest:lower() == "copy" then diagOpenCopyDialog()
          else diagPrintChat() end
        end,
      },
      {
        name = "debug",
        help = "Toggle the live debug console",
        run = function() toggleDebugConsole() end,
      },
    },
  })
else
  -- Cogworks v0.13+ is required for slash registration. Surface the failure
  -- explicitly so it doesn't masquerade as "slash silently broken".
  print("|cffff4040Tally:|r slash registration skipped — Cogworks v0.13+ required.")
end

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

  -- TLY-35: a skipped user is technically still "pending" (no completed
  -- flag, no imports), but they explicitly opted out of the setup nag.
  -- Click handlers keep using setupPending so the icon stays a re-entry
  -- point into the wizard; the tooltip + launcher text branch on this so
  -- "setup required" only screams at users who haven't decided yet.
  local function setupSkipped()
    return TallyDB and TallyDB.setup and TallyDB.setup.skipped and true or false
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
        -- TLY-35: skipped users get a calm, non-nagging variant — they
        -- already told us they're not ready. Keep it short and re-entry
        -- friendly so they can change their mind without feeling badgered.
        if setupSkipped() then
          tooltip:SetText("|cff888888Tally|r — setup skipped")
          tooltip:AddLine(" ")
          tooltip:AddLine("Setup was dismissed. Tally isn't tracking your data.",
            0.85, 0.85, 0.85, true)
          tooltip:AddLine("Re-run any time from /tally setup or Settings → Re-run setup wizard.",
            0.85, 0.85, 0.85, true)
          tooltip:AddLine(" ")
          tooltip:AddLine("Click to re-open setup.", 1, 0.82, 0, true)
          return
        end
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
      -- TLY-35: distinct text for "user opted out" vs "user hasn't decided".
      -- Skipped uses a quieter gray to match the calm tooltip; required
      -- keeps the gold/yellow attention pull for fresh installs.
      if setupSkipped() then
        dataobject.text = "|cff888888setup skipped|r"
        return
      end
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
