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
-- Schema gate — one-shot clean-break wipe (TLY-78)
-- ============================================================================
--
-- The projection-layer redesign (TLY-77/-78) retired the alpha18/19 store:
-- the TallyActive active blob, the TallyA001..A060 archive slots, and the
-- import/synthesis write paths are all gone. Tally now persists only what
-- is bounded by something other than trade volume (net-worth snapshots,
-- period aggregates, sparse overrides) and recomputes the ledger on parse.
--
-- This gate fires once per account to drop every retired structure so the
-- first projection-layer login lands clean. Tester data is expendable in
-- alpha (no migration). Settings, net-worth snapshots, strategy, minimap,
-- and theme are preserved.
--
-- Two gates, deliberately separate:
--   1. Account-wide gate (TallyDB.tally_schema_version): fires exactly
--      once per account. Wipes the retired ledger substrate + slot globals
--      + per-account setup flags so Char2's first login doesn't reintroduce
--      old shapes Char1 already cleared.
--   2. Per-character gate (TallyCharDB.tally_schema_version): fires once
--      per character. Clears TallyCharDB.tallyAcknowledged so each
--      character sees the welcome wizard once if account-wide setup hasn't
--      been completed yet.
local TALLY_SCHEMA_VERSION = 19

if (TallyDB.tally_schema_version or 0) < TALLY_SCHEMA_VERSION then
  TallyDB.ledger = nil  -- drops active, archives, archiveSlots, archiveIndex,
                        -- nextSlot, blob, blobMeta, entries, byId in one swing
  for i = 1, 60 do
    _G[string.format("TallyA%03d", i)] = nil
  end
  _G.TallyActive = nil
  TallyDB.import = nil          -- retired import-controller pending state
  TallyDB.setup = nil          -- welcome wizard re-fires so user opts in
  TallyDB.disabledSources = nil -- clean source-enable state
  TallyDB.tally_schema_version = TALLY_SCHEMA_VERSION
end

if (TallyCharDB.tally_schema_version or 0) < TALLY_SCHEMA_VERSION then
  TallyCharDB.tallyAcknowledged = nil
  TallyCharDB.tally_schema_version = TALLY_SCHEMA_VERSION
end

-- TLY-81: History.lua is retired — its net-worth role moved to
-- Spine/NetWorthStore.lua, and its per-item × per-character inventory
-- snapshots are the row-growing structure REDESIGN.md §3.2 forbids.
-- Drop the orphaned saved data. Unconditional + idempotent: nothing
-- recreates these keys now that History.lua is gone. This is a targeted
-- nil, deliberately not a TALLY_SCHEMA_VERSION bump — bumping the master
-- gate would re-wipe the still-live alpha18/19 ledger, which is #78's
-- job, not #81's. Per-item price history is tracked as TLY-91.
TallyDB.history = nil
TallyDB.pricingHistory = nil

-- ============================================================================
-- Event dispatch
-- ============================================================================
local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
-- TLY-68 gold capture surfaces
frame:RegisterEvent("PLAYER_MONEY")
frame:RegisterEvent("PLAYER_INTERACTION_MANAGER_FRAME_SHOW")
frame:SetScript("OnEvent", function(_, event, ...)
  local handler = ns[event]
  if handler then handler(ns, ...) end
end)

-- PLAYER_LOGOUT. The projection layer keeps no in-memory ledger to flush —
-- everything persisted (net-worth snapshots, aggregates, overrides) is
-- written eagerly when it changes — so there is nothing to do here. The
-- handler is retained as a hook point for future logout-time work.
function ns:PLAYER_LOGOUT()
end

-- TLY-68: refresh this character's captured gold whenever the running
-- balance changes. Cheap (single hash write); fires roughly per
-- transaction.
function ns:PLAYER_MONEY()
  if ns.Inventory and ns.Inventory.CaptureCurrentCharGold then
    pcall(ns.Inventory.CaptureCurrentCharGold, ns.Inventory)
  end
end

-- TLY-68: warband-bank money is only knowable when the player has the
-- account banker open. WoW fires PLAYER_INTERACTION_MANAGER_FRAME_SHOW
-- with Enum.PlayerInteractionType.AccountBanker (28 in retail) when
-- the warbank UI opens; capture then.
function ns:PLAYER_INTERACTION_MANAGER_FRAME_SHOW(interactionType)
  local ACCOUNT_BANKER = (Enum and Enum.PlayerInteractionType
                          and Enum.PlayerInteractionType.AccountBanker) or 28
  if interactionType == ACCOUNT_BANKER then
    if ns.Inventory and ns.Inventory.CaptureWarbandGold then
      pcall(ns.Inventory.CaptureWarbandGold, ns.Inventory)
    end
  end
end

function ns:PLAYER_LOGIN()
  -- TLY-81: prune net-worth snapshots past the retention window on login.
  if ns.Spine and ns.Spine.NetWorthStore then
    pcall(ns.Spine.NetWorthStore.Prune, ns.Spine.NetWorthStore)
  end
  if ns.Inventory and ns.Inventory.RegisterSyndicatorCallbacks then
    ns.Inventory:RegisterSyndicatorCallbacks()
  end
  -- TLY-68: capture this character's gold at PLAYER_LOGIN so NetWorth
  -- has a Tally-own value to prefer over Syndicator's snapshot. The
  -- subsequent PLAYER_MONEY handler keeps it fresh through the session;
  -- warband money piggybacks on the account-banker frame event.
  if ns.Inventory and ns.Inventory.CaptureCurrentCharGold then
    pcall(ns.Inventory.CaptureCurrentCharGold, ns.Inventory)
  end
  -- Register sibling source adapters. Each adapter registers its
  -- getEntriesFn with ns.Ledger; the spine's ParseCache parses the
  -- available ones lazily on first view open — no login-time parse, no
  -- per-login work that scales with ledger size.
  if ns.Sources then
    if ns.Sources.FlipQueue   then ns.Sources.FlipQueue:Register()   end
    if ns.Sources.TSM         then ns.Sources.TSM:Register()         end
    if ns.Sources.Journalator then ns.Sources.Journalator:Register() end
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
    if ns.UI.CreateInventoryPage then
      ns.UI.MainFrame:RegisterPage("Inventory", ns.UI.CreateInventoryPage)
    end
    -- TLY-78: the alpha18/19 view pages (Net Worth, Research, Lifecycle,
    -- Ledger, Compare) were removed in the projection-layer teardown. The
    -- new Live/Historical navigation + Summary/Ledger/Research views land
    -- in TLY-83..-87. Until then the data-spine verification tab is the
    -- ledger surface; Inventory + Settings + Appearance remain.
    TallyDB.ui = TallyDB.ui or {}
    -- TLY-77: data-spine verification tab — gated, default off. Debug
    -- surface for inspecting the spine's unified ledger.
    if TallyDB.ui.showSpineTab and ns.UI.CreateSpinePage then
      ns.UI.MainFrame:RegisterPage("Spine", ns.UI.CreateSpinePage)
    end
    if ns.UI.CreateSettingsPage then
      ns.UI.MainFrame:RegisterPage("Settings", ns.UI.CreateSettingsPage)
    end
    if ns.UI.CreateAppearancePage then
      ns.UI.MainFrame:RegisterPage("Appearance", ns.UI.CreateAppearancePage)
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
      -- TLY-81: refresh today's net-worth snapshot. MaybeSnapshot is
      -- debounced (min-interval), so this is cheap unless one is due.
      if ns.Spine and ns.Spine.NetWorthStore then
        ns.Spine.NetWorthStore:MaybeSnapshot()
      end
      -- Refresh open UI so live values stay current.
      if ns.UI and ns.UI.MainFrame and ns.UI.MainFrame:IsShown() then
        ns.UI.MainFrame:RefreshActivePage()
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
    GetNetWorthSnapshotAt = function(atTime)
      return ns.Spine and ns.Spine.NetWorthStore and ns.Spine.NetWorthStore:GetAt(atTime) or nil
    end,
    GetInventoryRollup = function() return ns.Inventory:Get() end,
    -- TLY-81: per-item price/inventory history retired with History.lua.
    -- Stubbed to empty until TLY-91 restores a bounded price-history store.
    GetItemPriceHistory = function() return {} end,
    GetItemPriceTrend = function() return nil end,
    GetItemInventoryHistory = function() return {} end,
    GetItemInventoryTrend = function() return nil end,
    QueryLedger = function(filter) return ns.Ledger:Query(filter) end,
    LedgerStats = function(filter) return ns.Ledger:Stats(filter) end,
    -- v1.5 (TLY-26 / TLY-27)
    GetItemLifecycle = function(itemID, opts) return ns.Lifecycle and ns.Lifecycle:GetRecord(itemID, opts) or nil end,
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

-- Wipes the data stores Tally accumulates at runtime — ledger, net-worth
-- snapshots, inventory rollup, the setup-completed flag, and any user
-- source opt-outs — then re-runs the inventory scan and re-shows the
-- setup wizard so the user lands back in the first-run flow. Config that
-- doesn't represent accumulated data is preserved (strategy, snapshot
-- retention, minimap, UI position).
--
-- The wizard handles the chunked backfill from sibling sources — reset
-- intentionally does NOT auto-import. Otherwise we'd race the wizard's
-- own backfill on Finish and double-insert / starve the user's input
-- thread before they've even picked a pace.
local function resetData()
  if ns.Ledger and ns.Ledger.Clear then ns.Ledger:Clear() end
  if ns.Spine and ns.Spine.NetWorthStore then ns.Spine.NetWorthStore:Clear() end
  TallyDB.aggregates = nil      -- recomputed from the spine on next parse
  TallyDB.merge = nil           -- sparse manual dedup/merge overrides
  TallyDB.inventoryRollup = nil
  TallyDB.setup = nil          -- clear completed flag so wizard re-fires
  TallyDB.disabledSources = nil -- re-let the user pick sources in the wizard

  if ns.Output then
    ns.Output:Info("Data cleared (ledger, net-worth snapshots, inventory rollup, setup state). Rebuilding inventory…")
  end

  if ns.Inventory and ns.Inventory.Rebuild then
    ns.Inventory:Rebuild()
  end

  -- Hand off to the setup wizard. Defer slightly so the rebuild broadcast
  -- + UI close races settle. There is no longer any backfill to drive —
  -- the spine recomputes from sibling sources on demand.
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
        if ns.Output then
          ns.Output:Success("Setup wizard reopened — Tally will recompute from your sources when you finish it.")
        end
      elseif ns.Output then
        ns.Output:Warn("Setup wizard unavailable — re-open Tally to recompute from your sources.")
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

-- Per-character gold accounting probe. Walks every character Syndicator
-- knows about plus every character in TallyDB.inventoryRollup, comparing
-- the two sides. Surfaces three failure modes that would silently
-- under-count a player's total gold:
--   * Syndicator has the char but `data.money` is nil → `or 0` fallback
--     in projectCharacter zeroes that char's contribution to net worth.
--   * Char is in GetAllCharacters() but GetByCharacterFullName returns
--     nil → projectCharacter returns nil and the rollup never gets an
--     entry for that char at all.
--   * Char is in the rollup but Syndicator no longer reports it →
--     stale rollup entry whose .gold reflects the last seen value.
-- Probes warband[1..4] separately in case the player has multiple WoW
-- accounts under one Bnet (each account has its own warband) — a setup
-- where Tally currently only reads warband[1].
local function inspectGold()
  local out = { perChar = {}, summary = {}, warbandProbe = {} }

  local available = type(_G.Syndicator) == "table" and type(_G.Syndicator.API) == "table"
  if not available then
    out.error = "Syndicator API unavailable"
    return out
  end

  local rollup       = TallyDB and TallyDB.inventoryRollup
  local rollupChars  = (rollup and rollup.characters) or {}

  local syndicatorChars = {}
  if _G.Syndicator.API.GetAllCharacters then
    local ok, chars = pcall(_G.Syndicator.API.GetAllCharacters)
    if ok and type(chars) == "table" then
      for _, ck in ipairs(chars) do syndicatorChars[ck] = true end
    end
  end

  local seen = {}
  for ck in pairs(syndicatorChars) do seen[ck] = true end
  for ck in pairs(rollupChars)      do seen[ck] = true end

  local sortedKeys = {}
  for ck in pairs(seen) do sortedKeys[#sortedKeys + 1] = ck end
  table.sort(sortedKeys)

  local synSum, rollupSum = 0, 0
  local nilMoney, zeroMoney, missingRollup, staleRollup = 0, 0, 0, 0

  for _, ck in ipairs(sortedKeys) do
    local e = { charKey = ck, sourceGold = {} }

    if syndicatorChars[ck] and _G.Syndicator.API.GetByCharacterFullName then
      local ok, data = pcall(_G.Syndicator.API.GetByCharacterFullName, ck)
      if ok and type(data) == "table" then
        e.syndicatorSeen  = true
        e.syndicatorMoney = data.money
        if data.money == nil then
          e.flag = "money-nil"
          nilMoney = nilMoney + 1
        elseif data.money == 0 then
          e.flag = "money-zero"
          zeroMoney = zeroMoney + 1
        end
        if type(data.money) == "number" then synSum = synSum + data.money end
      else
        e.syndicatorSeen = false
      end
    else
      e.syndicatorSeen = false
    end

    local rEntry = rollupChars[ck]
    if rEntry then
      e.inRollup   = true
      e.rollupGold = rEntry.gold or 0
      rollupSum    = rollupSum + e.rollupGold
      if not syndicatorChars[ck] then
        e.flag = e.flag or "stale-rollup"
        staleRollup = staleRollup + 1
      end
    else
      e.inRollup = false
      e.flag     = e.flag or "missing-from-rollup"
      missingRollup = missingRollup + 1
    end

    -- TLY-69 multi-source provenance: walk every registered gold source
    -- for this charKey, record per-source value + freshness, and capture
    -- the chosen winner (highest moneyAt). Surfaces which adapter is
    -- actually contributing to NetWorth's per-character gold.
    if ns.Inventory and ns.Inventory.ProbeCharGoldAll then
      local records = ns.Inventory:ProbeCharGoldAll(ck)
      for _, rec in ipairs(records) do
        e.sourceGold[rec.source] = { money = rec.money, moneyAt = rec.moneyAt }
      end
    end
    if ns.Inventory and ns.Inventory.PreferredCharGold then
      local money, chosenRec = ns.Inventory:PreferredCharGold(ck)
      e.chosenGold   = money
      e.chosenSource = chosenRec and chosenRec.source or nil
    end

    out.perChar[#out.perChar + 1] = e
  end

  -- Per-source totals across all chars + chosen total. Lets the report
  -- header surface "what would each source give us in aggregate" alongside
  -- the chosen-source view NetWorth actually uses.
  local sourceSumCopper = {}
  local chosenSumCopper = 0
  for _, e in ipairs(out.perChar) do
    if e.sourceGold then
      for src, rec in pairs(e.sourceGold) do
        sourceSumCopper[src] = (sourceSumCopper[src] or 0) + (rec.money or 0)
      end
    end
    chosenSumCopper = chosenSumCopper + (e.chosenGold or 0)
  end

  out.summary = {
    charCount               = #sortedKeys,
    syndicatorSumCopper     = synSum,
    rollupSumCopper         = rollupSum,
    deltaCopper             = synSum - rollupSum,
    nilMoneyCount           = nilMoney,
    zeroMoneyCount          = zeroMoney,
    missingFromRollupCount  = missingRollup,
    staleRollupCount        = staleRollup,
    sourceSumCopper         = sourceSumCopper,
    chosenSumCopper         = chosenSumCopper,
  }

  if _G.Syndicator.API.GetWarband then
    for idx = 1, 4 do
      local ok, wb = pcall(_G.Syndicator.API.GetWarband, idx)
      if ok and type(wb) == "table" then
        out.warbandProbe[idx] = { money = wb.money }
      end
    end
  end

  if rollup and rollup.warband then
    out.warband = {
      rollupGold = rollup.warband.gold or 0,
    }
  end

  return out
end

local function inspectLedger()
  if not (ns.Ledger and ns.Ledger.Stats) then return nil end
  local stats = ns.Ledger:Stats({})
  return { rowCount = stats.count, bySource = stats.sources }
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
  end
  return out
end

local function inspectNetWorthSnapshots()
  if not (ns.Spine and ns.Spine.NetWorthStore) then return nil end
  local sum = ns.Spine.NetWorthStore:GetSummary()
  return {
    snapshots      = sum.snapshotCount or 0,
    oldestAt       = sum.oldestAt,
    lastSnapshotAt = sum.lastSnapshotAt,
  }
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
  { name = "Gold",            fn = inspectGold },
  { name = "Ledger",          fn = inspectLedger },
  { name = "SkipCounters",    fn = inspectSkipCounters },
  { name = "NetWorthSnapshots", fn = inspectNetWorthSnapshots },
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

-- Human-readable formatted diagnostic dump. Walks each inspector and
-- pretty-prints its output as plain text suitable for routing into
-- ns.Output:Inspect (copy-dialog). Same data as DumpDebugState but
-- shaped for human reading + paste-into-issue. Colour codes stripped —
-- the copy dialog renders them as literal escape sequences otherwise.
local function diagFormatPretty()
  local lines = {}
  local function emit(s) lines[#lines + 1] = s end

  emit("== Tally diagnostic ==")
  emit("(copy this into a GitHub issue if you're reporting a bug)")

  local v = inspectVersions()
  emit(string.format("Tally: %s  |  Cogworks: %s  |  Interface: %s",
    v.tally, v.cogworks, v.interface))

  local s = inspectSetup()
  emit(string.format("Setup: completed=%s  grandfathered=%s",
    describeBoolean(s.completed), describeBoolean(s.grandfathered)))

  local syn = inspectSyndicator()
  emit(string.format("Syndicator: loaded=%s  API.GetAllCharacters=%s",
    describeBoolean(syn.loaded), describeBoolean(syn.hasGetAllCharacters)))
  if syn.characters then
    emit(string.format("  Syndicator chars (%d):", syn.characterCount))
    for i, ck in ipairs(syn.characters) do
      if i > 10 then
        emit(string.format("    … and %d more", syn.characterCount - 10))
        break
      end
      emit("    - " .. tostring(ck))
    end
  elseif syn.characterError then
    emit("  Syndicator GetAllCharacters() failed: " .. syn.characterError)
  end

  local inv = inspectInventory()
  if inv.missing then
    emit("Inventory rollup: MISSING — never built. Try /tally rescan.")
  else
    emit(string.format("Inventory rollup: %d chars, %d distinct items, last scan %s",
      inv.charCount, inv.distinctItems, describeAgeAgo(inv.lastScanAge)))
    if inv.warband then
      emit(string.format("  Warband: gold=%s, distinct items=%d",
        ns.NetWorth.FormatGold(inv.warband.gold), inv.warband.distinctItems))
    end
    if #inv.emptyChars > 0 then
      emit("  Chars with 0 items in rollup: " .. table.concat(inv.emptyChars, ", "))
    end
  end

  local cur = inspectCurrentChar()
  if cur.seenBySyndicator ~= nil then
    emit(string.format("Current char (%s): seen by Syndicator=%s",
      cur.charKey, describeBoolean(cur.seenBySyndicator)))
  end
  if cur.syndicatorGoldFields then
    emit(string.format("  Syndicator gold fields: money=%s gold=%s copper=%s",
      tostring(cur.syndicatorGoldFields.money),
      tostring(cur.syndicatorGoldFields.gold),
      tostring(cur.syndicatorGoldFields.copper)))
  end
  if cur.inRollup ~= nil then
    emit(string.format("  In rollup: %s (%d distinct items, gold=%s)",
      cur.inRollup and "yes" or "NO",
      cur.rollupItems or 0,
      cur.rollupGold and ns.NetWorth.FormatGold(cur.rollupGold) or "—"))
  end

  local wb = inspectWarbandProbe()
  if wb then
    if wb.error then
      emit("Warband: GetWarband(1) returned " .. wb.error)
    else
      emit(string.format("Warband (idx=1): money=%s gold=%s copper=%s",
        tostring(wb.money), tostring(wb.gold), tostring(wb.copper)))
    end
  end

  local lg = inspectLedger()
  if lg then
    emit(string.format("Ledger: %d rows", lg.rowCount))
    if next(lg.bySource or {}) then
      for src, n in pairs(lg.bySource) do
        emit(string.format("  %s: %d", src, n))
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
      emit(string.format("  %s skipped %d rows since last load:", label, entry.total))
      local rs = {}
      for r, n in pairs(entry.reasons) do rs[#rs + 1] = string.format("    %s: %d", r, n) end
      table.sort(rs)
      for _, line in ipairs(rs) do emit(line) end
    end
  end

  local nw = inspectNetWorthSnapshots()
  if nw then
    emit(string.format("Net-worth snapshots: %d", nw.snapshots))
  end

  local ds = inspectDisabledSources()
  if ds then
    emit("Disabled sources: " .. table.concat(ds, ", "))
  end

  local sib = inspectSiblings()
  local sibOrder = { "TSM", "FlipQueue", "Journalator", "Auctionator" }
  local sibLine = "Siblings: "
  for i, name in ipairs(sibOrder) do
    if i > 1 then sibLine = sibLine .. "  " end
    sibLine = sibLine .. name .. "=" .. (sib[name] and "yes" or "no")
  end
  emit(sibLine)

  local m = inspectMemory()
  if m then
    emit(string.format("Memory: %.1f KB", m.kb))
  end

  emit("== end diagnostic ==")
  return table.concat(lines, "\n")
end

local function diagPrettyCopyDialog()
  if ns.Output then
    ns.Output:Inspect(diagFormatPretty(),
      "Tally pretty-formatted diagnostic — paste into a GitHub issue.")
  end
end

-- Paste-friendly variant: opens Cogworks's CreateCopyDialog with the
-- DumpDebugState output (Lua-table format, structured, easy to diff
-- between testers). Falls back to the pretty-formatted copy-dialog if
-- the Cogworks debug toolkit is unavailable for any reason.
local function diagOpenCopyDialog()
  if not (Cogworks and Cogworks.DumpDebugState and Cogworks.CreateCopyDialog) then
    diagPrettyCopyDialog()
    return
  end
  registerDiagInspectors()
  local dump = Cogworks:DumpDebugState("Tally")
  Cogworks:CreateCopyDialog(dump, "Paste this into a GitHub issue when reporting a bug.")
end

-- Sibling cogs hold a reference to ns.Diag — preserve the contract.
-- The pretty-formatted copy-dialog is the human-readable variant.
ns.Diag = diagPrettyCopyDialog
ns.DiagCopyDialog = diagOpenCopyDialog
ns.RegisterDiagInspectors = registerDiagInspectors

-- ============================================================================
-- /tally spine — data-spine readout (TLY-79 / TLY-80)
-- ============================================================================
--
-- The projection-layer redesign's verification surface while the spine is
-- still additive (the old store is retired later, TLY-78). Shows the parse
-- cache state, per-source row counts, and — once the cache is ready — the
-- recompute-on-parse dedup/merge summary. `/tally spine parse` forces a
-- re-parse and opens the readout when it settles.

local function spineFormatReport()
  local lines = {}
  local function emit(s) lines[#lines + 1] = s end
  local fmt = BreakUpLargeNumbers or tostring

  emit("== Tally data-spine ==")
  local PC = ns.Spine and ns.Spine.ParseCache
  if not PC then
    emit("Spine modules not loaded.")
    emit("== end ==")
    return table.concat(lines, "\n")
  end

  emit(string.format("Enabled: %s",
    PC:IsEnabled() and "yes" or "no — escape-hatch flag is off (/tally spine on)"))
  local st = PC:GetState()
  emit(string.format("Parse phase: %s  (%d / %d sources)",
    st.phase or "?", st.done or 0, st.total or 0))
  if st.currentSource then
    emit("Currently parsing: " .. st.currentSource)
  end
  if st.sources and #st.sources > 0 then
    emit("Sources:")
    for _, slot in ipairs(st.sources) do
      if slot.status == "done" then
        emit(string.format("  %-12s %s rows%s", slot.name, fmt(slot.count or 0),
          (slot.skipped and slot.skipped > 0)
            and string.format(" (%d skipped)", slot.skipped) or ""))
      elseif slot.status == "error" then
        emit(string.format("  %-12s ERROR: %s", slot.name, tostring(slot.error)))
      else
        emit(string.format("  %-12s %s", slot.name, slot.status or "pending"))
      end
    end
  end

  if PC:IsReady() and ns.Spine.Dedup then
    local ok, _, summary = pcall(ns.Spine.Dedup.run, PC:GetAllEntries())
    if ok and summary then
      emit("")
      emit("Dedup/merge (recompute-on-parse):")
      emit(string.format("  %s parsed entries -> %s unified records",
        fmt(summary.entries), fmt(summary.records)))
      emit(string.format("  %s cross-source merges, %s flagged for review",
        fmt(summary.merged), fmt(summary.review)))
    end
  end
  if PC:IsReady() and ns.Spine.UnifiedLedger then
    local ok, stats = pcall(ns.Spine.UnifiedLedger.Stats, ns.Spine.UnifiedLedger)
    if ok and stats then
      local realmCount = 0
      for _ in pairs(stats.byRealm or {}) do realmCount = realmCount + 1 end
      emit("")
      emit("Unified ledger (post-override projection):")
      emit(string.format("  %s records across %d realm%s",
        fmt(stats.count), realmCount, realmCount == 1 and "" or "s"))
      emit(string.format("  %s flagged for review", fmt(stats.review)))
    end
  end
  if ns.Spine.Aggregates then
    local ok, asum = pcall(ns.Spine.Aggregates.Summary, ns.Spine.Aggregates)
    if ok and asum then
      emit(string.format("Aggregates: %d periods, %s records folded%s",
        asum.periods, fmt(asum.records),
        asum.stale and " (stale — re-parse)" or ""))
    end
  end
  if ns.Spine.Overrides then
    emit(string.format("Manual overrides stored: %d", ns.Spine.Overrides:Count()))
  end
  emit("== end ==")
  return table.concat(lines, "\n")
end

local function spineCopyDialog()
  if ns.Output then
    ns.Output:Inspect(spineFormatReport(),
      "Tally data-spine status — paste into a GitHub issue.")
  end
end

-- Focused gold-accounting report. Columnar per-character listing of
-- Syndicator-reported money vs Tally rollup gold, with summary totals
-- and warband[1..4] probes. Companion to inspectGold above; this is the
-- paste-friendly text formatter for `/tally diag gold`.
local function formatGoldReport()
  local g = inspectGold()
  if g.error then
    return "=== Tally — gold accounting report ===\n" .. g.error
  end

  local function gFromCopper(copper)
    return math.floor((copper or 0) / 10000)
  end

  local function fmtG(copper)
    return BreakUpLargeNumbers and BreakUpLargeNumbers(gFromCopper(copper))
                              or tostring(gFromCopper(copper))
  end

  local lines = {}
  local push = function(s) lines[#lines + 1] = s end

  push("=== Tally — gold accounting report ===")
  push("Generated: " .. date("%Y-%m-%d %H:%M:%S"))
  push("")

  local s = g.summary
  push(string.format("Characters seen (Syndicator + rollup): %d", s.charCount or 0))
  push(string.format("Chosen total (NetWorth uses): %s g", fmtG(s.chosenSumCopper)))
  if s.sourceSumCopper then
    local srcNames = {}
    for name in pairs(s.sourceSumCopper) do srcNames[#srcNames + 1] = name end
    table.sort(srcNames)
    for _, name in ipairs(srcNames) do
      push(string.format("  %-12s total: %s g", name, fmtG(s.sourceSumCopper[name])))
    end
  end
  push(string.format("Rollup total (legacy, pre-TLY-69):  %s g", fmtG(s.rollupSumCopper)))
  push(string.format("Syndicator total (raw):            %s g", fmtG(s.syndicatorSumCopper)))
  push(string.format("Delta (syn - rollup):              %s g", fmtG(s.deltaCopper)))

  if (s.nilMoneyCount or 0) > 0 then
    push(string.format(">> %d characters report nil .money in Syndicator data", s.nilMoneyCount))
  end
  if (s.zeroMoneyCount or 0) > 0 then
    push(string.format(">> %d characters report .money = 0", s.zeroMoneyCount))
  end
  if (s.missingFromRollupCount or 0) > 0 then
    push(string.format(">> %d Syndicator characters are missing from Tally rollup", s.missingFromRollupCount))
  end
  if (s.staleRollupCount or 0) > 0 then
    push(string.format(">> %d rollup characters are no longer in Syndicator", s.staleRollupCount))
  end

  -- TLY-69: list every registered gold source (deterministic order from
  -- Inventory's registry) so the per-character table can column-align.
  local sourceOrder = {}
  if ns.Inventory and ns.Inventory.GetGoldSources then
    for _, name in ipairs(ns.Inventory:GetGoldSources()) do
      sourceOrder[#sourceOrder + 1] = name
    end
  end

  push("")
  push("Per-character (sorted by chosen gold descending):")

  -- Header row: charKey + each registered source + chosen + source-of-choice
  local headerCols = { string.format("  %-40s", "charKey") }
  for _, name in ipairs(sourceOrder) do
    headerCols[#headerCols + 1] = string.format("%-14s", name)
  end
  headerCols[#headerCols + 1] = string.format("%-14s", "chosen")
  headerCols[#headerCols + 1] = string.format("%-12s", "source")
  headerCols[#headerCols + 1] = "flag"
  push(table.concat(headerCols, "  "))

  table.sort(g.perChar, function(a, b)
    return (a.chosenGold or a.syndicatorMoney or -1) > (b.chosenGold or b.syndicatorMoney or -1)
  end)

  for _, e in ipairs(g.perChar) do
    local row = { string.format("  %-40s", e.charKey) }
    for _, name in ipairs(sourceOrder) do
      local rec = e.sourceGold and e.sourceGold[name]
      local cell = rec and (fmtG(rec.money) .. " g") or "—"
      row[#row + 1] = string.format("%-14s", cell)
    end
    local chosenStr = e.chosenGold and (fmtG(e.chosenGold) .. " g") or "—"
    row[#row + 1] = string.format("%-14s", chosenStr)
    row[#row + 1] = string.format("%-12s", e.chosenSource or "—")
    row[#row + 1] = e.flag or ""
    push(table.concat(row, "  "))
  end

  push("")
  push("Warband:")
  if g.warband then
    push(string.format("  Rollup gold: %s g", fmtG(g.warband.rollupGold)))
  end
  for idx = 1, 4 do
    local p = g.warbandProbe[idx]
    if p then
      local m = p.money and (fmtG(p.money) .. " g") or "(nil)"
      push(string.format("  Syndicator warband[%d].money: %s", idx, m))
    end
  end

  return table.concat(lines, "\n")
end

local function goldCopyDialog()
  local text = formatGoldReport()
  if ns.Output then
    ns.Output:Inspect(text, "Tally gold report — paste into a GitHub issue.")
  end
end

ns.GoldReportText = formatGoldReport
ns.GoldCopyDialog = goldCopyDialog

-- ============================================================================
-- Sibling-source metadata probe (alpha18 simulated-import readout)
-- ============================================================================
--
-- Calls :ProbeMetadata() on each registered sibling adapter (FlipQueue,
-- TSM, Journalator) and rolls the per-source readouts into a single
-- copy-dialog table. The probe is read-only and reuses each adapter's
-- own walking code — the cheapest fidelity-preserving accounting we
-- can produce of "what would alpha19's import controller have to chew."
--
-- TSM and Journalator probes are O(rows) with one field read per row;
-- on big-tester accounts (90k+ TSM rows) that's a multi-second blocking
-- pass. The user-visible help text flags this as one-time diagnostic
-- work, not a recurring command.

local function probeSibling(name, label, source)
  if not source then
    return { name = name, label = label, available = false }
  end
  if type(source.ProbeMetadata) ~= "function" then
    return { name = name, label = label, available = false,
             error = "adapter has no ProbeMetadata method" }
  end
  local ok, result = pcall(source.ProbeMetadata, source)
  if not ok then
    return { name = name, label = label, available = false,
             error = "ProbeMetadata threw: " .. tostring(result) }
  end
  result.name  = name
  result.label = label
  return result
end

local function inspectSourcesProbe()
  return {
    flipqueue   = probeSibling("flipqueue",   "FlipQueue",      ns.Sources and ns.Sources.FlipQueue),
    tsm         = probeSibling("tsm",         "TSM Accounting", ns.Sources and ns.Sources.TSM),
    journalator = probeSibling("journalator", "Journalator",    ns.Sources and ns.Sources.Journalator),
  }
end

-- Approximates the worst-case 60-day import window by summing each pair
-- of consecutive months in the byMonth distribution and returning the
-- max. Resolution is per-month (~30-62 days per pair) — close enough to
-- size the alpha19 per-cycle row budget for the manual import controller.
local function compute60dPeak(byMonth)
  if type(byMonth) ~= "table" then return 0 end
  local months = {}
  for mk, n in pairs(byMonth) do months[#months + 1] = { mk = mk, n = n } end
  table.sort(months, function(a, b) return a.mk < b.mk end)
  local peak = 0
  for i = 1, #months do
    local sum = months[i].n + (months[i + 1] and months[i + 1].n or 0)
    if sum > peak then peak = sum end
  end
  return peak
end

local function formatSourcesProbeReport()
  local probes = inspectSourcesProbe()
  local order = { "flipqueue", "tsm", "journalator" }

  local lines = {}
  local push = function(s) lines[#lines + 1] = s end
  local fmtNum = function(n)
    return BreakUpLargeNumbers and BreakUpLargeNumbers(n or 0) or tostring(n or 0)
  end

  push("=== Tally — sibling-source metadata probe ===")
  push("Generated: " .. date("%Y-%m-%d %H:%M:%S"))
  push("")
  push("Per-source totals + 60-day import window peak:")
  push(string.format("  %-12s  %-9s  %-12s  %-25s  %-12s",
                     "source", "available", "rows", "span", "60d peak"))

  -- Collect month-keys present in any source so the per-month table
  -- below has a consistent column space across sources.
  local monthSet = {}
  for _, key in ipairs(order) do
    local p = probes[key]
    if p.byMonth then for mk in pairs(p.byMonth) do monthSet[mk] = true end end
  end
  local months = {}
  for mk in pairs(monthSet) do months[#months + 1] = mk end
  table.sort(months, function(a, b) return a > b end)  -- newest first

  for _, key in ipairs(order) do
    local p = probes[key]
    if not p.available then
      local why = p.error or "not detected"
      push(string.format("  %-12s  %-9s  %s", p.name, "no", why))
    else
      local span = "(no timestamped rows)"
      if p.fromTs and p.toTs then
        span = date("%Y-%m-%d", p.fromTs) .. " .. " .. date("%Y-%m-%d", p.toTs)
      end
      push(string.format("  %-12s  %-9s  %-12s  %-25s  %-12s",
                         p.name, "yes", fmtNum(p.count), span, fmtNum(compute60dPeak(p.byMonth))))
    end
  end

  if #months > 0 then
    push("")
    push("Per-month distribution (newest first):")
    push(string.format("  %-9s  %-12s  %-12s  %-12s",
                       "month", "flipqueue", "tsm", "journalator"))
    for _, mk in ipairs(months) do
      push(string.format("  %-9s  %-12s  %-12s  %-12s", mk,
        fmtNum((probes.flipqueue.byMonth   or {})[mk] or 0),
        fmtNum((probes.tsm.byMonth         or {})[mk] or 0),
        fmtNum((probes.journalator.byMonth or {})[mk] or 0)))
    end
  end

  push("")
  push("Notes:")
  for _, key in ipairs(order) do
    local p = probes[key]
    if p.available and p.notes then
      push(string.format("  %s: %s", p.name, p.notes))
    end
  end
  push("")
  push("This probe is the alpha18 simulated-import readout for sizing")
  push("alpha19's per-cycle row budget. The 60d peak is the headline number")
  push("— the worst-case window a single import push would have to chew.")

  return table.concat(lines, "\n")
end

local function sourcesCopyDialog()
  local text = formatSourcesProbeReport()
  if ns.Output then
    ns.Output:Inspect(text, "Tally sibling-source probe — paste into a GitHub issue.")
  end
end

ns.SourcesProbeReportText = formatSourcesProbeReport
ns.SourcesCopyDialog = sourcesCopyDialog

-- Live debug console — opens Cogworks's CreateDebugConsole({ cog = "Tally" }).
-- Singleton: one console instance reused across slash invocations. Position,
-- size, and pinned state persist into TallyDB.ui.debugConsole.
local debugConsole
local function toggleDebugConsole()
  if not (Cogworks and Cogworks.CreateDebugConsole) then
    if ns.Output then
      ns.Output:Error("Debug console requires Cogworks v0.13+. Update Cogworks-1.0.")
    end
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
  rest = (rest or ""):match("^%s*(.-)%s*$")

  -- "at <duration>" → reconstruct historical snapshot.
  local atArg = rest:match("^at%s+(.+)$")
  if atArg then
    local offsetSec = parsePastOffsetSec(atArg)
    if not offsetSec then
      if ns.Output then
        ns.Output:Error("Usage: /tally networth at -<duration> (e.g. -7d, -1h, -30m)")
      end
      return
    end
    local NWS = ns.Spine and ns.Spine.NetWorthStore
    if not NWS then
      if ns.Output then ns.Output:Error("Net-worth snapshot store unavailable.") end
      return
    end
    local rec = NWS:GetAt(time() - offsetSec)
    if not rec then
      if ns.Output then
        ns.Output:Error("No net-worth snapshot at or before that time.")
      end
      return
    end
    -- NetWorthStore keeps a lean per-day record (no per-character /
    -- warband breakdown — that history isn't stored). Build a
    -- print-shaped table so PrintSnapshot renders the totals it has.
    local snap = {
      view        = includeBound and "owned" or "net",
      strategy    = rec.strategy,
      total       = includeBound and rec.ownedTotal or rec.total,
      gold        = rec.gold,
      items       = includeBound and rec.ownedItems or rec.items,
      breakdown   = rec.breakdown,
      warband     = { gold = 0, items = 0, total = 0 },
      byCharacter = {},
      atTime      = rec.atTime,
    }
    local label = string.format("(at %s, %s ago)",
      date("%Y-%m-%d %H:%M", rec.atTime), describeAge(offsetSec))
    ns.NetWorth:PrintSnapshot(snap, label)
    -- Δ vs current
    local current = ns.NetWorth:Snapshot({ includeBound = includeBound })
    local delta = current.total - snap.total
    local sign = delta >= 0 and "+" or "-"
    local pct = ""
    if snap.total > 0 then
      pct = string.format(" (%s%.1f%%)", delta >= 0 and "+" or "-", math.abs(delta / snap.total) * 100)
    end
    if ns.Output then
      ns.Output:ChatRaw(string.format("  Δ vs now: %s%s%s",
        sign, ns.NetWorth.FormatGold(math.abs(delta)), pct))
    end
    return
  end

  if rest ~= "" then
    if ns.Output then
      ns.Output:Error("Unknown net-worth subcommand. Try /tally networth or /tally networth at -7d.")
    end
    return
  end

  ns.NetWorth:Print({ includeBound = includeBound })
end

local function handleHistory(args)
  local sub, rest = args:match("^(%S*)%s*(.*)$")
  sub = (sub or ""):lower()

  local NWS = ns.Spine and ns.Spine.NetWorthStore
  if not NWS then
    if ns.Output then ns.Output:Error("Net-worth snapshot store unavailable.") end
    return
  end

  if sub == "" or sub == "status" or sub == "config" then
    local cfg = NWS:GetConfig()
    local summary = NWS:GetSummary()
    local now = time()
    local lines = {}
    local function push(s) lines[#lines + 1] = s end
    push("Tally net-worth snapshots")
    push(string.format("  cadence: one per day, retention %d days",
      cfg.retentionDays or 180))
    if summary.snapshotCount == 0 then
      push("  (no snapshots yet)")
    else
      local ageLast = summary.lastSnapshotAt and (now - summary.lastSnapshotAt) or nil
      local span = (summary.lastSnapshotAt and summary.oldestAt)
        and (summary.lastSnapshotAt - summary.oldestAt) or 0
      push(string.format("  %d snapshots, last %s ago, spanning %s",
        summary.snapshotCount, describeAge(ageLast), describeAge(span)))
    end
    if ns.Output then
      ns.Output:Inspect(table.concat(lines, "\n"), "Tally net-worth snapshot summary.")
    end
    return
  end

  if sub == "snapshot" then
    local ok, info = NWS:MaybeSnapshot({ force = true })
    if ok and ns.Output then
      ns.Output:Success("Net-worth snapshot recorded — "
        .. ns.NetWorth.FormatGold(info.total) .. ".")
    elseif not ok and ns.Output then
      ns.Output:Error("Snapshot skipped — " .. tostring(info))
    end
    return
  end

  if sub == "retention" then
    local days = tonumber(rest)
    if not days or days <= 0 then
      if ns.Output then ns.Output:Error("Usage: /tally history retention <days>") end
      return
    end
    local ok, e = NWS:SetRetentionDays(days)
    if ok and ns.Output then ns.Output:Success("Retention set to " .. math.floor(days) .. "d.")
    elseif not ok and ns.Output then ns.Output:Error(tostring(e)) end
    return
  end

  if sub == "clear" then
    NWS:Clear()
    if ns.Output then ns.Output:Success("Net-worth snapshots cleared.") end
    return
  end

  if ns.Output then
    ns.Output:Error("Unknown history subcommand '" .. sub .. "'. Try /tally history.")
  end
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
          if ns.UI and ns.UI.MainFrame then
            ns.UI.MainFrame:Toggle()
          elseif ns.Output then
            ns.Output:Error("UI module unavailable.")
          end
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
            if ns.UI and ns.UI.ShowResearch then
              ns.UI.ShowResearch(nil)
            elseif ns.Output then
              ns.Output:Info("Usage: /tally research <itemlink-or-id>")
            end
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
            if ns.Output then
              ns.Output:Info("Usage: /tally research-chat <itemlink-or-id>")
            end
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
          if ok and ns.Output then ns.Output:Success("Inventory rescanned.")
          elseif not ok and ns.Output then ns.Output:Error("Rescan failed — " .. tostring(err)) end
        end,
      },
      {
        name = "history", aliases = { "h" },
        args = "[status|snapshot|retention|clear]",
        help = "Net-worth snapshot summary / take snapshot now / set retention days / clear",
        run = function(rest) handleHistory(rest) end,
      },
      {
        name = "strategy",
        args = "[<expression>]",
        help = "Print or set price strategy",
        run = function(rest)
          rest = rest or ""
          if rest == "" then
            if ns.Output then
              ns.Output:Info("Price strategy = " .. ns.NetWorth:GetStrategy())
            end
          else
            local ok, err = ns.NetWorth:SetStrategy(rest)
            if ok and ns.Output then
              ns.Output:Success("Price strategy set to '" .. rest .. "'.")
            elseif not ok and ns.Output then
              ns.Output:Error(tostring(err))
            end
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
          elseif ns.Output then
            ns.Output:Warn(
              "/tally reset confirm wipes ledger + history + inventory rollup. "
              .. "Settings (strategy, history cadence, minimap, UI prefs) are preserved.",
              { duration = 8 })
          end
        end,
      },
      {
        name = "setup", aliases = { "wizard" },
        help = "Re-run the first-time setup wizard",
        run = function()
          if ns.UI and ns.UI.ShowSetupWizard then
            ns.UI.ShowSetupWizard()
          elseif ns.Output then
            ns.Output:Error("Setup wizard unavailable.")
          end
        end,
      },
      {
        name = "inventory", aliases = { "inv" },
        args = "[charKey]",
        help = "Open the per-character inventory drill-down",
        run = function(rest)
          if ns.UI and ns.UI.ShowInventory then
            ns.UI.ShowInventory((rest and rest ~= "") and rest or nil)
          elseif ns.Output then
            ns.Output:Error("Inventory page unavailable.")
          end
        end,
      },
      {
        name = "diag", aliases = { "diagnostic" },
        args = "[gold|sources|chat]",
        -- TLY-70: every diag subcommand routes through CreateCopyDialog.
        -- `pretty` (also alias `chat` for muscle-memory) opens the human-
        -- readable formatted variant; default opens the structured
        -- DumpDebugState (Lua-table) variant. Both are paste-ready into
        -- a GitHub issue; pick whichever reads more cleanly to the eye.
        help = "Open diagnostic dump as a copy dialog. `gold` for per-character gold accounting; `sources` for sibling-source row counts + monthly distribution (runs a multi-second blocking parse on big TSM CSVs); `pretty` (or `chat`) for the human-readable formatted variant.",
        run = function(rest)
          local sub = rest and rest:lower() or ""
          if sub == "gold" then goldCopyDialog()
          elseif sub == "sources" then sourcesCopyDialog()
          elseif sub == "pretty" or sub == "chat" then diagPrettyCopyDialog()
          else diagOpenCopyDialog() end
        end,
      },
      {
        name = "spine",
        args = "[parse|status|on|off]",
        help = "Data-spine diagnostics (TLY-79/80 projection-layer redesign). `parse` re-parses sibling sources into the session cache and opens the readout when it settles; `status` (default) opens the current spine readout; `on`/`off` toggle the escape-hatch flag.",
        run = function(rest)
          local sub = rest and rest:lower() or ""
          local PC = ns.Spine and ns.Spine.ParseCache
          if sub == "parse" then
            if not PC then
              if ns.Output then ns.Output:Error("Spine not loaded.") end
              return
            end
            if not PC:IsEnabled() then
              if ns.Output then
                ns.Output:Warn("Spine is disabled — `/tally spine on` to enable.")
              end
              return
            end
            if ns.Output then
              ns.Output:Info("Spine: parsing sibling sources…")
            end
            PC:RegisterListener("slash-spine-parse", function(st)
              if st.phase == "ready" or st.phase == "error" then
                PC:UnregisterListener("slash-spine-parse")
                spineCopyDialog()
              end
            end)
            PC:Refresh()
          elseif sub == "on" then
            if PC then
              PC:SetEnabled(true)
              if ns.Output then ns.Output:Success("Spine enabled.") end
            end
          elseif sub == "off" then
            if PC then
              PC:SetEnabled(false)
              if ns.Output then ns.Output:Info("Spine disabled.") end
            end
          else
            spineCopyDialog()
          end
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
  -- explicitly so it doesn't masquerade as "slash silently broken". Output
  -- router gracefully degrades to chat if Cogworks itself is missing or
  -- below the Toast threshold.
  if ns.Output then
    ns.Output:Error("Slash registration skipped — Cogworks v0.13+ required.")
  end
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
        if not (ns.Spine and ns.Spine.NetWorthStore) then return end
        local past = ns.Spine.NetWorthStore:GetAt(time() - windowSec)
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
