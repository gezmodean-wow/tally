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
-- alpha18 schema gate — one-shot wipe + structural reshape
-- ============================================================================
--
-- alpha18 splits the active blob into its own SV (TallyActive) so
-- TallyDB no longer holds anything that grows with row count — the
-- structural fix for the alpha13/alpha16 constant-pool overflow that
-- broke big-tester accounts.
--
-- Two gates, deliberately separate:
--   1. Account-wide gate (TallyDB.tally_schema_version): fires exactly
--      once per account. Wipes ledger substrate + per-account setup
--      flags + slot globals so the first alpha18 login lands in a clean
--      state. Account-wide so Char2's first alpha18 login doesn't
--      clobber rows Char1 captured between its wipe and Char2's first
--      session.
--   2. Per-character gate (TallyCharDB.tally_schema_version): fires
--      once per character. Clears TallyCharDB.tallyAcknowledged so
--      each character sees the alpha18 welcome wizard once if account-
--      wide setup hasn't been completed yet.
--
-- Tester data is expendable in alpha (no migration). Settings, history
-- snapshots, net-worth strategy, minimap, and theme are preserved.
local TALLY_SCHEMA_VERSION = 18

if (TallyDB.tally_schema_version or 0) < TALLY_SCHEMA_VERSION then
  TallyDB.ledger = nil  -- drops active, archives, archiveSlots, archiveIndex,
                        -- nextSlot, blob, blobMeta, entries, byId in one swing
  for i = 1, 60 do
    _G[string.format("TallyA%03d", i)] = nil
  end
  _G.TallyActive = nil
  TallyDB.setup = nil          -- welcome wizard re-fires so user opts in
  TallyDB.disabledSources = nil -- clean source-enable state
  TallyDB.tally_schema_version = TALLY_SCHEMA_VERSION
end

if (TallyCharDB.tally_schema_version or 0) < TALLY_SCHEMA_VERSION then
  TallyCharDB.tallyAcknowledged = nil
  TallyCharDB.tally_schema_version = TALLY_SCHEMA_VERSION
end

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

-- PLAYER_LOGOUT is the canonical "save the working memory back to disk"
-- point. WoW writes SavedVariables after every addon's PLAYER_LOGOUT
-- handler returns, so this is our chance to serialise the active set
-- before WoW persists the SV chunk.
function ns:PLAYER_LOGOUT()
  if ns.Ledger and ns.Ledger.SaveToDisk then
    pcall(ns.Ledger.SaveToDisk, ns.Ledger)
  end
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
  -- TLY-21: force a one-shot history prune on login so users coming from the
  -- pre-fix legacy defaults (365d retention) immediately reclaim memory once
  -- the migration in History.db() trims their config to 90d.
  if ns.History and ns.History.Prune then
    pcall(ns.History.Prune, ns.History)
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
  -- TLY-45: open a session-window log entry. Pairs with the periodic
  -- heartbeat ticker further down so DivergenceReport can categorize
  -- ledger gaps as real (Tally was running, should have captured) vs
  -- expected (Tally wasn't running, sibling backfill is the truth).
  if ns.Ledger and ns.Ledger.StartSession then
    local tocVer = (C_AddOns and C_AddOns.GetAddOnMetadata
                    and C_AddOns.GetAddOnMetadata(addonName, "Version")) or "?"
    pcall(ns.Ledger.StartSession, ns.Ledger, {
      build   = (GetBuildInfo and select(4, GetBuildInfo())) or nil,
      version = tostring(tocVer),
      charKey = ns.Inventory and ns.Inventory.CurrentCharKey
                and ns.Inventory:CurrentCharKey() or nil,
    })
  end
  -- Register ledger source adapters. Each adapter registers itself with
  -- ns.Ledger; we then run the available ones to backfill on login.
  if ns.Sources then
    if ns.Sources.Native      then ns.Sources.Native:Register()      end
    if ns.Sources.FlipQueue   then ns.Sources.FlipQueue:Register()   end
    if ns.Sources.TSM         then ns.Sources.TSM:Register()         end
    if ns.Sources.Journalator then ns.Sources.Journalator:Register() end
  end
  -- alpha18 active-only baseline: PLAYER_LOGIN registers Native event
  -- capture (above) and that's it. No automatic sibling-source
  -- import, no session-row dirty, no per-login work that scales with
  -- total ledger size. The flipper loop's 60× login tax was the
  -- driving objective for the rewrite — anything that grew with row
  -- count had to leave PLAYER_LOGIN.
  --
  -- Sibling import returns in alpha19+ as a user-initiated, pausable,
  -- resumable wizard flow with a per-cycle row budget — never as
  -- silent login work.

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

  -- TLY-31 Phase B / TLY-45: the 5-minute periodic auto-import is gone.
  -- Sibling adapters are now strictly backfill-only — the one-shot at
  -- PLAYER_LOGIN above (line ~112) handles the catch-up; nothing reruns
  -- on a ticker. Per the alpha10 strategy discussion, we replace the
  -- auto-import cycle with two diagnostics:
  --
  --   1. Heartbeat ticker (60s) — extends the current session's
  --      lastSeenAt so DivergenceReport can tell which ledger gaps
  --      occurred while Tally was running (real-gap candidates) vs
  --      while it wasn't (expected gap, what backfill is for).
  --   2. One-shot divergence check (~60s after login) — runs
  --      Ledger:DivergenceReport, logs a one-line summary to chat
  --      ("Tally: divergence check — N real gaps. /tally diag
  --      divergence to inspect."). Auto-fire is silent if zero real
  --      gaps so it stays out of the way; full detail lives behind
  --      the slash command.
  --
  -- Manual "Import from <source>" buttons in Settings keep working —
  -- they're now framed as backfill, not periodic refresh, in the UI.
  if ns.Ledger and ns.Ledger.HeartbeatSession and C_Timer and C_Timer.NewTicker then
    C_Timer.NewTicker(60, function()
      pcall(ns.Ledger.HeartbeatSession, ns.Ledger)
    end)
  end

  if ns.Ledger and ns.Ledger.DivergenceReport and C_Timer and C_Timer.After then
    C_Timer.After(60, function()
      if not ns.Ledger:IsSetupComplete() then return end
      local ok, report = pcall(ns.Ledger.DivergenceReport, ns.Ledger)
      if not ok or not report then return end
      local n = report.summary.realGapCount
      if n and n > 0 and ns.Output then
        ns.Output:Warn(
          string.format("Divergence check found %d real gap%s — click to inspect.",
                        n, n == 1 and "" or "s"),
          { onClick = function() divergenceCopyDialog() end, duration = 8 })
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
  if ns.Ledger and ns.Ledger.Clear then ns.Ledger:Clear() end
  if ns.History and ns.History.Clear then ns.History:Clear() end
  TallyDB.inventoryRollup = nil
  TallyDB.setup = nil          -- clear completed flag so wizard re-fires
  TallyDB.disabledSources = nil -- re-let the user pick sources in the wizard

  if ns.Output then
    ns.Output:Info("Data cleared (ledger, history, inventory rollup, setup state). Rebuilding inventory…")
  end

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
        if ns.Output then
          ns.Output:Success("Setup wizard reopened — your data will be re-imported when you finish it.")
        end
      else
        -- Wizard unavailable (no Cogworks v0.11.0?). Fall back to the old
        -- behaviour: synchronous slurp. Better than leaving the user with
        -- an empty ledger.
        if ns.Output then
          ns.Output:Warn("Setup wizard unavailable; running synchronous backfill instead.")
        end
        if ns.Ledger and ns.Ledger.ImportFromAllSources then
          local results = ns.Ledger:ImportFromAllSources()
          local total = 0
          for _, r in ipairs(results) do total = total + (r.inserted or 0) end
          if ns.Output then
            ns.Output:Success(string.format("Reset complete — %d ledger entries re-imported.", total))
          end
        end
      end
    end)
  end
end

ns.Reset = resetData

-- ============================================================================
-- /tally seed — synthetic ledger generator for TLY-51 stress testing
-- ============================================================================
--
-- Two modes, both used to exercise the alpha16 storage paths without
-- needing a real tester's 438k-row account:
--
--   /tally seed N
--     Generates N synthetic entries spread across the last 12 months
--     and chunked-inserts them via the live route — current-month
--     rows go to active, prior-month rows go to staging buckets, then
--     FlushStaging writes archives. Exercises the routed-import +
--     archive-creation paths.
--
--   /tally seed legacy N
--     Generates N entries, packs them as an alpha14/15 single-blob
--     directly into TallyDB.ledger.blob, and clears the new-shape
--     fields. Run /reload after — Tally's loadFromDisk treats it like
--     a real legacy upgrader and kicks off the migration pass.
--     Exercises the migration path.
--
--   /tally seed clear
--     Removes every entry whose source == "__seed" from active and
--     archives. Use to clean up after stress testing.
--
-- Distribution is intentionally uniform over time + crude on item /
-- char / kind variety — enough to make Reconcile's clustering
-- realistic but not trying to model real trader behaviour. The
-- pseudo-source name "__seed" keeps these rows quarantined from real
-- ledger views (filter by source = "__seed" to inspect them; ClearSource
-- "__seed" wipes them).

local SEED_SOURCE = "__seed"

local SEED_KINDS = {
  "sale", "purchase", "ah-cancel", "ah-expire",
  "vendor-sell", "vendor-buy", "ah-fee",
}

local SEED_CHARS = {
  "Stress1-StressTest", "Stress2-StressTest", "Stress3-StressTest",
  "Stress4-StressTest", "Stress5-StressTest",
}

local function buildSeedEntry(i, now, rangeSec)
  local atTime = now - math.random(1, rangeSec)
  local kind = SEED_KINDS[((i - 1) % #SEED_KINDS) + 1]
  local copper
  if kind == "ah-cancel" or kind == "ah-expire" then
    copper = 0
  elseif kind == "ah-fee" then
    copper = math.random(100, 500000)
  else
    copper = math.random(1000, 100000000)
  end
  return {
    id       = SEED_SOURCE .. ":" .. tostring(i),
    atTime   = atTime,
    kind     = kind,
    itemID   = 100000 + ((i * 17) % 5000),
    itemKey  = tostring(100000 + ((i * 17) % 5000)),
    charKey  = SEED_CHARS[((i - 1) % #SEED_CHARS) + 1],
    copper   = copper,
    count    = math.random(1, 5),
    source   = SEED_SOURCE,
    sourceId = tostring(i),
    meta     = { name = "Stress test item " .. tostring((i % 200) + 1) },
  }
end

-- Synchronous generator — fine for small N. Used by tests + as a
-- fallback when C_Timer is unavailable.
local function generateSeedEntries(count, monthsBack)
  count = count or 100000
  monthsBack = monthsBack or 12
  local now = time()
  local rangeSec = monthsBack * 30 * 86400
  local entries = {}
  for i = 1, count do
    entries[i] = buildSeedEntry(i, now, rangeSec)
  end
  return entries
end

-- Chunked generator. Builds the entry list across C_Timer ticks so a
-- 200k-row seed doesn't freeze the input thread before routing even
-- begins. Calls onComplete(entries) when done.
--
-- Default chunkSize 1500 keeps each tick under ~15ms on slower CPUs
-- (each entry build is ~9μs — 1500 entries ≈ 13ms = under one frame
-- at 60fps; 5000 entries was hitting ~45ms = ~23fps in tester reports).
local function generateSeedEntriesChunked(count, monthsBack, opts)
  count = count or 100000
  monthsBack = monthsBack or 12
  opts = opts or {}
  local chunkSize = opts.chunkSize or 1500
  local delaySec  = opts.delaySec or 0.005
  local now = time()
  local rangeSec = monthsBack * 30 * 86400

  if not (C_Timer and C_Timer.After) then
    if opts.onComplete then pcall(opts.onComplete, generateSeedEntries(count, monthsBack)) end
    return
  end

  local entries = {}
  local idx = 0

  local function step()
    local stop = math.min(idx + chunkSize, count)
    while idx < stop do
      idx = idx + 1
      entries[idx] = buildSeedEntry(idx, now, rangeSec)
    end
    if opts.onProgress then pcall(opts.onProgress, idx, count) end
    if idx < count then
      C_Timer.After(delaySec, step)
    else
      if opts.onComplete then pcall(opts.onComplete, entries) end
    end
  end

  step()
end

local function handleSeed(rest)
  rest = rest or ""
  local sub, arg = rest:match("^(%S*)%s*(.-)$")
  sub = sub or ""

  -- /tally seed clear
  if sub == "clear" then
    if not (ns.Ledger and ns.Ledger.ClearSourceAsync) then
      if ns.Output then ns.Output:Error("Ledger unavailable.") end
      return
    end
    if ns.Output then ns.Output:Info("Clearing seeded entries (chunked across archives)…") end
    ns.Ledger:ClearSourceAsync(SEED_SOURCE, {
      onProgress = function(idx, total, key, removedSoFar)
        if ns.Output then
          ns.Output:Debug(string.format("seed clear scanned %s (%d / %d), %d removed so far",
            key or "?", idx, total, removedSoFar or 0))
        end
      end,
      onComplete = function(totalRemoved)
        if ns.Output then
          ns.Output:Success(string.format("Cleared %d seeded entries from active + archives.",
            totalRemoved or 0))
        end
        if ns.UI and ns.UI.MainFrame then
          if ns.UI.MainFrame.UpdateHeaderNudge then
            pcall(ns.UI.MainFrame.UpdateHeaderNudge, ns.UI.MainFrame)
          end
          if ns.UI.MainFrame.RefreshActivePage then
            pcall(ns.UI.MainFrame.RefreshActivePage, ns.UI.MainFrame)
          end
        end
      end,
    })
    return
  end

  -- /tally seed legacy N
  if sub == "legacy" then
    local n = tonumber(arg) or 100000
    local LibSerialize = LibStub and LibStub("LibSerialize", true)
    local LibDeflate   = LibStub and LibStub("LibDeflate", true)
    if not (LibSerialize and LibDeflate) then
      if ns.Output then ns.Output:Error("LibSerialize / LibDeflate unavailable.") end
      return
    end

    if ns.Output then
      ns.Output:Info(string.format("Generating %d synthetic entries (chunked)…", n))
    end
    generateSeedEntriesChunked(n, 12, {
      onProgress = function(idx, total)
        if ns.Output then
          ns.Output:Debug(string.format("seed legacy generated %d / %d", idx, total))
        end
      end,
      onComplete = function(entries)
        local byId = {}
        for _, e in ipairs(entries) do byId[e.id] = true end

        -- Serialise async — synchronous serialise of 100k+ rows busts WoW's
        -- ~10s script execution timer (LibSerialize is pure-Lua and walks
        -- every entry in one pass). The async handler yields every 4096
        -- items so the work spreads across ticks. After completion, run
        -- the (smaller, faster) compress synchronously.
        if ns.Output then
          ns.Output:Info("Serialising async (yields every 4096 items)…")
        end
        local handler = LibSerialize:SerializeAsync({ entries = entries, byId = byId })
        local function step()
          local ok, completed, serialised = pcall(handler)
          if not ok then
            if ns.Output then
              ns.Output:Error("Serialise failed: " .. tostring(completed))
            end
            return
          end
          if not completed then
            if C_Timer and C_Timer.After then
              C_Timer.After(0.005, step)
            else
              step()
            end
            return
          end

          if ns.Output then
            ns.Output:Info(string.format("Serialise complete (%d bytes); compressing…", #serialised))
          end
          local compressed = LibDeflate:CompressDeflate(serialised, { level = 1 })

          TallyDB = TallyDB or {}
          -- Wipe slot-resident archives + archiveSlots + archiveIndex
          -- so loadFromDisk routes cleanly through the legacy path
          -- on /reload. Walk the slot table before nuking it so each
          -- slot global is cleared and its SV file becomes empty.
          if ns.Archive then
            for _, k in ipairs(ns.Archive:List()) do ns.Archive:Delete(k) end
            ns.Archive:UnloadAll()
          end
          TallyDB.ledger = TallyDB.ledger or {}
          TallyDB.ledger.blob = compressed
          TallyDB.ledger.blobMeta = {
            count   = n,
            savedAt = time(),
            bytes   = #compressed,
          }
          -- Clear all new-shape fields so loadFromDisk routes through
          -- the legacy alpha14/15 single-blob path.
          TallyDB.ledger.active        = nil
          TallyDB.ledger.activeMeta    = nil
          TallyDB.ledger.archives      = nil
          TallyDB.ledger.archiveIndex  = nil
          TallyDB.ledger.archiveSlots  = nil
          TallyDB.ledger.nextSlot      = nil

          -- IMPORTANT: also wipe in-memory ledger state. Without this,
          -- the in-memory active set persists; PLAYER_LOGOUT's
          -- SaveToDisk would re-serialise it back to
          -- TallyDB.ledger.active AND clear the legacy blob we just
          -- wrote (the migration-completion clear in SaveToDisk).
          -- Result on next /reload: legacy blob gone, no migration
          -- exercised.
          --
          -- This is destructive — the caller's real ledger goes away.
          -- Acceptable for stress-testing; document in the slash help.
          if ns.Ledger and ns.Ledger.WipeForLegacySeed then
            ns.Ledger:WipeForLegacySeed()
          end

          if ns.Output then
            ns.Output:Success(string.format(
              "Wrote %d entries to legacy blob (%d bytes compressed, %d serialised). In-memory active wiped — legacy blob is the only ledger now. Run /reload to detect the legacy blob and start migration.",
              n, #compressed, #serialised))
          end
        end
        step()
      end,
    })
    return
  end

  -- /tally seed N (default)
  local n = tonumber(sub) or tonumber(rest) or 100000
  if n < 1 then n = 100000 end

  if not (ns.Ledger and ns.Ledger.InsertManyChunkedRouted) then
    if ns.Output then
      ns.Output:Error("Tiered storage unavailable — InsertManyChunkedRouted missing.")
    end
    return
  end

  if ns.Output then
    ns.Output:Info(string.format("Generating %d synthetic entries (chunked)…", n))
  end
  generateSeedEntriesChunked(n, 12, {
    onProgress = function(idx, total)
      if ns.Output then
        ns.Output:Debug(string.format("seed generated %d / %d", idx, total))
      end
    end,
    onComplete = function(entries)
      if ns.Output then ns.Output:Info("Routing into active + staging…") end
      ns.Ledger:InsertManyChunkedRouted(entries, {
        chunkSize = 500,
        delaySec  = 0.005,
        onProgress = function(inserted, total)
          if ns.Output then
            ns.Output:Debug(string.format("seed routed %d / %d (%d%%)",
              inserted, total, math.floor(100 * inserted / total)))
          end
        end,
        onDone = function(inserted, skipped, insertedActive, insertedStaging)
          if ns.Output then
            ns.Output:Success(string.format(
              "Seeded %d entries — %d to active, %d to staging buckets (%d skipped).",
              inserted, insertedActive or 0, insertedStaging or 0, skipped or 0))
          end
          if ns.Ledger.GetStagingRowCount and ns.Ledger:GetStagingRowCount() > 0 then
            if ns.Output then ns.Output:Info("Flushing staging buckets to archives…") end
            ns.Ledger:FlushStaging({
              delaySec = 0.005,
              onProgress = function(idx, total, key)
                if ns.Output then
                  ns.Output:Debug(string.format("seed flush %s (%d / %d)", key or "?", idx, total))
                end
              end,
              onComplete = function(archivesWritten, rowsArchived)
                if ns.Output then
                  ns.Output:Success(string.format(
                    "Flush complete — %d archives, %d archived rows.",
                    archivesWritten, rowsArchived))
                end
                if ns.UI and ns.UI.MainFrame and ns.UI.MainFrame.UpdateHeaderNudge then
                  pcall(ns.UI.MainFrame.UpdateHeaderNudge, ns.UI.MainFrame)
                end
              end,
            })
          else
            if ns.UI and ns.UI.MainFrame and ns.UI.MainFrame.UpdateHeaderNudge then
              pcall(ns.UI.MainFrame.UpdateHeaderNudge, ns.UI.MainFrame)
            end
          end
        end,
      })
    end,
  })
end

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
    local e = { charKey = ck }

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

    out.perChar[#out.perChar + 1] = e
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
  return { rowCount = stats.count, bySource = stats.bySource }
end

-- Storage inspector. Surfaces the tiered active set + archive cohort:
-- LibSerialize + LibDeflate availability, lazy-load + dirty state,
-- active row count + on-disk active blob size, archive count + total
-- archive bytes, and the LRU cache state.
local function inspectStorage()
  if not (ns.Ledger and ns.Ledger.StorageInfo) then return nil end
  return ns.Ledger:StorageInfo()
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
  { name = "Gold",            fn = inspectGold },
  { name = "Ledger",          fn = inspectLedger },
  { name = "Storage",         fn = inspectStorage },
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

  local st = inspectStorage()
  if st then
    print(string.format(
      "Storage: libs=%s loaded=%s dirty=%s schema=v%d%s",
      st.libsAvailable and "yes" or "|cffff8080NO|r",
      st.loaded and "yes" or "no",
      st.dirty and "yes" or "no",
      st.schemaVer or 0,
      st.legacyPresent and " |cffffa050[legacy blob still on disk]|r" or ""))
    if st.pendingLegacyLoad then
      print(string.format("  |cffffe080Legacy load pending:|r %d rows in legacy blob (%d bytes compressed) — async deserialise in flight",
        st.pendingLegacyRows or 0, st.pendingLegacyBytes or 0))
    end
    if st.pendingMigration then
      print(string.format("  |cffffe080Migration pending:|r %d rows in pendingMigration buffer", st.pendingRows or 0))
    end
    if st.stagingRows and st.stagingRows > 0 then
      print(string.format("  |cffffe080Staging:|r %d rows across %d buckets — flush on import completion",
        st.stagingRows, st.stagingKeys and #st.stagingKeys or 0))
    end
    print(string.format("  Active: %d rows, %d bytes", st.activeRows or 0, st.activeBytes or 0))
    if st.activeSavedAt and st.activeSavedAt > 0 then
      print(string.format("    saved %s  (serialise %dms + compress %dms; serialised %d bytes)",
        date("%Y-%m-%d %H:%M:%S", st.activeSavedAt),
        st.serialiseMs or 0, st.compressMs or 0, st.serialisedBytes or 0))
    end
    if (st.archiveCount or 0) > 0 then
      if (st.archiveBytes or 0) > 0 then
        print(string.format("  Archives: %d archives, %d rows, %d bytes",
          st.archiveCount, st.archiveRows or 0, st.archiveBytes))
      else
        print(string.format("  Archives: %d archives, %d rows (slot-resident, raw)",
          st.archiveCount, st.archiveRows or 0))
      end
      local cached = st.cachedArchives or {}
      if #cached > 0 then
        print(string.format("    Cache: %d/%d loaded — %s",
          #cached, st.cacheCap or 3, table.concat(cached, ", ")))
      end
      -- Surface slot-allocator state for diag purposes.
      if ns.Archive and ns.Archive.DiagInfo then
        local info = ns.Archive:DiagInfo()
        if info then
          print(string.format("    Slots: %d / %d allocated", info.nextSlot or 0, info.slotCount or 0))
          if (info.legacyCount or 0) > 0 then
            print(string.format("    |cffffa050%d unmigrated legacy archive(s)|r — will migrate on next access",
              info.legacyCount))
          end
        end
      end
    end
    print(string.format("  Total rows: %d (active + archives)", st.totalRows or st.activeRows or 0))
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

-- ============================================================================
-- /tally diag divergence — multi-source coverage analysis (TLY-45)
-- ============================================================================
--
-- Walks Ledger:DivergenceReport and renders it as a paste-friendly text
-- block: source counts, real gaps (Tally was running, sibling has the
-- event but Native doesn't), expected gaps (Tally wasn't running),
-- field disagreements (clusters where multiple sources captured the
-- event but disagree on copper / atTime / etc).
--
-- The check is the diagnostic complement of Reconcile: Reconcile picks
-- field values when sources agree on existence; this surfaces where
-- they disagree on existence so the user can act ("install Native /
-- check why TSM rows aren't getting paired" etc.).
--
-- Truncation: real gaps are listed in full (always actionable), but
-- expected gaps and field disagreements truncate to MAX_DETAIL each
-- so the dialog doesn't balloon to thousands of lines on a power user's
-- ledger. The summary header carries the full counts for context.

local DIVERGENCE_MAX_DETAIL = 25

local function formatDivergenceReport()
  if not (ns.Ledger and ns.Ledger.DivergenceReport) then
    return "Divergence report unavailable — Ledger:DivergenceReport missing."
  end
  local report = ns.Ledger:DivergenceReport()
  local lines = {}
  local function emit(s) lines[#lines + 1] = s end

  emit("Tally divergence report — generated " .. date("%Y-%m-%d %H:%M"))
  emit("")

  -- Session coverage header. Pulls a 7-day window for a quick "how
  -- much of last week was Tally observing" headline; the full session
  -- list is in the regular /tally diag dump for power users.
  if ns.Ledger.SessionCoverage then
    local weekAgo = time() - 7 * 86400
    local total, overlapping, coveredSec = ns.Ledger:SessionCoverage(weekAgo, time())
    local hours = coveredSec / 3600
    emit(string.format(
      "Sessions logged: %d (last 7d: %d sessions, %.1fh of observation)",
      total, overlapping, hours))
  end
  emit(string.format(
    "Total clusters: %d  |  multi-source: %d  |  field-disagreement: %d  |  real-gap: %d  |  expected-gap: %d",
    report.summary.clusters,
    report.summary.multiSourceClusters,
    report.summary.fieldDisagreementCount,
    report.summary.realGapCount,
    report.summary.expectedGapCount))
  emit("")

  -- Source contribution counts. Stable order so cross-tester diffs read
  -- consistently — alphabetical by source name.
  local sourceNames = {}
  for k in pairs(report.summary.sourceCounts) do sourceNames[#sourceNames + 1] = k end
  table.sort(sourceNames)
  emit("SOURCE CONTRIBUTIONS (rows seen, before reconciliation)")
  for _, name in ipairs(sourceNames) do
    emit(string.format("  %-16s %d", name, report.summary.sourceCounts[name]))
  end
  emit("")

  -- Real gaps — Tally was running, sibling has the event, Native didn't
  -- capture. These are the bugs we care about.
  emit("REAL GAPS — events sibling sources observed while Tally was running")
  if #report.realGap == 0 then
    emit("  (none — Native captured every event observed during a session)")
  else
    for _, item in ipairs(report.realGap) do
      local c = item.cluster
      local first = c[1]
      local sources = {}
      for _, e in ipairs(c) do sources[#sources + 1] = e.source or "?" end
      table.sort(sources)
      local itemDesc = (first.meta and first.meta.name)
                    or (first.itemID and ("item:" .. first.itemID))
                    or "(no item)"
      emit(string.format("  %s | %s | %s | %s | sources=%s | session=%s",
        date("%Y-%m-%d %H:%M:%S", first.atTime or 0),
        first.kind or "?",
        first.charKey or "?",
        itemDesc,
        table.concat(sources, "+"),
        date("%Y-%m-%d %H:%M", item.sessionRef.startedAt or 0)))
    end
  end
  emit("")

  -- Expected gaps — Tally wasn't running. Truncated.
  emit(string.format("EXPECTED GAPS — events while Tally wasn't running (showing first %d of %d)",
    math.min(#report.expectedGap, DIVERGENCE_MAX_DETAIL), #report.expectedGap))
  for i = 1, math.min(#report.expectedGap, DIVERGENCE_MAX_DETAIL) do
    local c = report.expectedGap[i].cluster
    local first = c[1]
    local sources = {}
    for _, e in ipairs(c) do sources[#sources + 1] = e.source or "?" end
    table.sort(sources)
    local itemDesc = (first.meta and first.meta.name)
                  or (first.itemID and ("item:" .. first.itemID))
                  or "(no item)"
    emit(string.format("  %s | %s | %s | %s | sources=%s",
      date("%Y-%m-%d %H:%M:%S", first.atTime or 0),
      first.kind or "?",
      first.charKey or "?",
      itemDesc,
      table.concat(sources, "+")))
  end
  emit("")

  -- Field disagreements — same event captured by 2+ sources but they
  -- disagree on values. Reconcile picks the priority winner; this
  -- shows where the picks happen.
  emit(string.format("FIELD DISAGREEMENTS — multi-source clusters with conflicting values (showing first %d of %d)",
    math.min(#report.fieldDisagreement, DIVERGENCE_MAX_DETAIL),
    #report.fieldDisagreement))
  for i = 1, math.min(#report.fieldDisagreement, DIVERGENCE_MAX_DETAIL) do
    local entry = report.fieldDisagreement[i]
    local c = entry.cluster
    local first = c[1]
    local itemDesc = (first.meta and first.meta.name)
                  or (first.itemID and ("item:" .. first.itemID))
                  or "(no item)"
    local fieldDetails = {}
    for _, field in ipairs(entry.fields) do
      local pieces = {}
      for _, e in ipairs(c) do
        if e[field] ~= nil then
          pieces[#pieces + 1] = string.format("%s=%s",
            e.source or "?", tostring(e[field]))
        end
      end
      fieldDetails[#fieldDetails + 1] = field .. "[" .. table.concat(pieces, ", ") .. "]"
    end
    emit(string.format("  %s | %s | %s | %s | %s",
      date("%Y-%m-%d %H:%M:%S", first.atTime or 0),
      first.kind or "?",
      first.charKey or "?",
      itemDesc,
      table.concat(fieldDetails, "; ")))
  end

  return table.concat(lines, "\n")
end

local function divergenceCopyDialog()
  local text = formatDivergenceReport()
  if ns.Output then
    ns.Output:Inspect(text, "Tally divergence report — paste into a GitHub issue or external tool.")
  end
end

ns.DivergenceReportText = formatDivergenceReport
ns.DivergenceCopyDialog = divergenceCopyDialog

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
  push(string.format("Syndicator total: %s g", fmtG(s.syndicatorSumCopper)))
  push(string.format("Rollup total:     %s g", fmtG(s.rollupSumCopper)))
  push(string.format("Delta (syn - rollup): %s g", fmtG(s.deltaCopper)))

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

  push("")
  push("Per-character (sorted by Syndicator gold descending):")
  push(string.format("  %-40s  %-14s  %-14s  %s", "charKey", "syndicator", "rollup", "flag"))

  table.sort(g.perChar, function(a, b)
    return (a.syndicatorMoney or -1) > (b.syndicatorMoney or -1)
  end)

  for _, e in ipairs(g.perChar) do
    local synStr = e.syndicatorMoney
                   and (fmtG(e.syndicatorMoney) .. " g")
                   or  "(nil)"
    local rolStr = e.inRollup
                   and (fmtG(e.rollupGold) .. " g")
                   or  "(missing)"
    local flag   = e.flag or ""
    push(string.format("  %-40s  %-14s  %-14s  %s", e.charKey, synStr, rolStr, flag))
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
    if not ns.History or not ns.History.GetNetWorthAt then
      if ns.Output then ns.Output:Error("History module unavailable.") end
      return
    end
    local atTime = time() - offsetSec
    local snap, info = ns.History:GetNetWorthAt(atTime, { includeBound = includeBound })
    if not snap then
      if ns.Output then ns.Output:Error(tostring(info or "No historical data.")) end
      return
    end
    local label = string.format("(at %s, %s ago)",
      date("%Y-%m-%d %H:%M", snap.atTime), describeAge(offsetSec))
    local text = ns.NetWorth:FormatSnapshot(snap, label)
    if info and info ~= "" then text = text .. "\n  note: " .. tostring(info) end
    -- Δ vs current
    local current = ns.NetWorth:Snapshot({ includeBound = includeBound })
    local delta = current.total - snap.total
    local sign = delta >= 0 and "+" or "-"
    local pct = ""
    if snap.total > 0 then
      pct = string.format(" (%s%.1f%%)", delta >= 0 and "+" or "-", math.abs(delta / snap.total) * 100)
    end
    text = text .. string.format("\n  Δ vs now: %s%s%s",
      sign, ns.NetWorth.FormatGold(math.abs(delta)), pct)
    if ns.Output then
      ns.Output:Inspect(text, "Tally historical net-worth snapshot.")
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

  if sub == "" or sub == "config" then
    local cfg = ns.History:GetConfig()
    local summary = ns.History:GetSummary()
    local now = time()
    local lines = {}
    local function push(s) lines[#lines + 1] = s end
    push("Tally history config")
    push(string.format("  interval: %s (0 = disabled)", describeAge(cfg.minIntervalSec)))
    push(string.format("  retention: %s", describeAge(cfg.retentionSec)))
    push(string.format("  daily-rollup after: %s", describeAge(cfg.rollupAfterSec)))
    push("  pricing:")
    if #summary.pricing == 0 then
      push("    (no snapshots yet)")
    else
      for _, row in ipairs(summary.pricing) do
        local ageLast = row.lastSnapshotAt and (now - row.lastSnapshotAt) or nil
        local span = (row.lastSnapshotAt and row.oldestAt) and (row.lastSnapshotAt - row.oldestAt) or 0
        push(string.format("    [%s] %d snapshots, last %s ago, spanning %s",
          row.strategy, row.snapshotCount, describeAge(ageLast), describeAge(span)))
      end
    end
    local inv = summary.inventory
    if inv.snapshotCount == 0 then
      push("  inventory: (no snapshots yet)")
    else
      local ageLast = inv.lastSnapshotAt and (now - inv.lastSnapshotAt) or nil
      local span = (inv.lastSnapshotAt and inv.oldestAt) and (inv.lastSnapshotAt - inv.oldestAt) or 0
      push(string.format("  inventory: %d snapshots, last %s ago, spanning %s",
        inv.snapshotCount, describeAge(ageLast), describeAge(span)))
    end
    if ns.Output then
      ns.Output:Inspect(table.concat(lines, "\n"), "Tally history config + snapshot summary.")
    end
    return
  end

  if sub == "snapshot" then
    local ok, info = ns.History:Snapshot({ force = true })
    if ok and ns.Output then
      ns.Output:Success(string.format("Snapshot recorded under %s — %d priced items, %d inventory items.",
        info.strategy, info.pricedItems, info.inventoryItems))
    elseif not ok and ns.Output then
      ns.Output:Error("Snapshot skipped — " .. tostring(info))
    end
    return
  end

  if sub == "interval" then
    local hours = tonumber(rest)
    if not hours or hours < 0 then
      if ns.Output then
        ns.Output:Error("Usage: /tally history interval <hours> (0 disables auto-snapshot)")
      end
      return
    end
    local ok, e = ns.History:SetInterval(hours * 3600)
    if ok and ns.Output then ns.Output:Success("Interval set to " .. hours .. "h.")
    elseif not ok and ns.Output then ns.Output:Error(tostring(e)) end
    return
  end

  if sub == "retention" then
    local days = tonumber(rest)
    if not days or days <= 0 then
      if ns.Output then ns.Output:Error("Usage: /tally history retention <days>") end
      return
    end
    local ok, e = ns.History:SetRetention(days * 86400)
    if ok and ns.Output then ns.Output:Success("Retention set to " .. days .. "d.")
    elseif not ok and ns.Output then ns.Output:Error(tostring(e)) end
    return
  end

  if sub == "rollup" then
    local days = tonumber(rest)
    if not days or days <= 0 then
      if ns.Output then ns.Output:Error("Usage: /tally history rollup <days>") end
      return
    end
    local ok, e = ns.History:SetRollupThreshold(days * 86400)
    if ok and ns.Output then ns.Output:Success("Daily-rollup threshold set to " .. days .. "d.")
    elseif not ok and ns.Output then ns.Output:Error(tostring(e)) end
    return
  end

  if sub == "clear" then
    local target = rest ~= "" and rest or nil
    ns.History:Clear(target)
    if ns.Output then
      ns.Output:Success("History cleared" .. (target and (" for " .. target) or "") .. ".")
    end
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
        name = "lifecycle", aliases = { "lc" },
        args = "<itemlink-or-id>",
        help = "Open per-item lifecycle drill-down",
        run = function(rest)
          if ns.UI and ns.UI.ShowLifecycle then
            ns.UI.ShowLifecycle(rest)
          elseif ns.Output then
            ns.Output:Error("Lifecycle UI unavailable.")
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
          elseif ns.Output then
            ns.Output:Error("Compare view unavailable.")
          end
        end,
      },
      {
        name = "seed",
        args = "[N | legacy N | clear]",
        help = "Generate synthetic ledger entries for stress-testing (debug only)",
        run = function(rest) handleSeed(rest) end,
      },
      {
        name = "seal",
        args = "[preview|confirm]",
        help = "Move ledger rows older than 60 days into monthly archives",
        run = function(rest)
          if not (ns.Ledger and ns.Ledger.Seal) then
            if ns.Output then ns.Output:Error("Seal unavailable.") end
            return
          end
          if ns.Ledger:IsMigrationRunning() then
            if ns.Output then
              ns.Output:Warn("Migration in progress — wait for it to finish before sealing.")
            end
            return
          end
          if ns.Ledger:IsSealRunning() then
            if ns.Output then ns.Output:Warn("Seal already running.") end
            return
          end

          local sub = rest and rest:lower() or ""
          local preview = ns.Ledger:SealPreview()

          if sub == "preview" or (sub ~= "confirm" and preview.sealCount > 5000) then
            local lines = {
              string.format("Tally seal preview: %d active rows  →  keep %d, archive %d",
                preview.activeCount, preview.keepCount, preview.sealCount),
            }
            if preview.cutTime then
              lines[#lines + 1] = string.format("Cut: rows older than %s; max active rows %d.",
                date("%Y-%m-%d", preview.cutTime), preview.maxRows)
            end
            if sub ~= "preview" then
              lines[#lines + 1] = "Large cut — run `/tally seal confirm` to proceed."
            end
            if ns.Output then
              ns.Output:Inspect(table.concat(lines, "\n"), "Tally seal preview.")
            end
            return
          end

          if preview.sealCount == 0 then
            if ns.Output then
              ns.Output:Info("Nothing to seal — active set is within the soft cap.")
            end
            return
          end

          if ns.Output then
            ns.Output:Info(string.format("Sealing %d rows into archives…", preview.sealCount))
          end
          ns.Ledger:Seal({
            onProgress = function(phase, idx, total, key)
              if phase == "bucket" and total > 0 and idx % 5000 == 0 and ns.Output then
                ns.Output:Debug(string.format("seal bucketing %d / %d", idx, total))
              elseif phase == "flush" and ns.Output then
                ns.Output:Debug(string.format("seal flush archive %s (%d / %d)",
                  key or "?", idx, total))
              end
            end,
            onComplete = function(sealed, archivesWritten)
              if ns.Output then
                ns.Output:Success(string.format(
                  "Sealed %d rows into %d archives. Logout will save the slimmed active set.",
                  sealed, archivesWritten))
              end
              if ns.UI and ns.UI.MainFrame then
                if ns.UI.MainFrame.UpdateHeaderNudge then
                  pcall(ns.UI.MainFrame.UpdateHeaderNudge, ns.UI.MainFrame)
                end
                if ns.UI.MainFrame.RefreshActivePage then
                  pcall(ns.UI.MainFrame.RefreshActivePage, ns.UI.MainFrame)
                end
              end
            end,
          })
        end,
      },
      {
        name = "diag", aliases = { "diagnostic" },
        args = "[divergence|gold|chat]",
        -- TLY-45 + alpha10 debug-UX: default opens the structured copy
        -- dialog (was: chat dump). Chat is preserved as `/tally diag
        -- chat` for users who specifically want inline output. `copy`
        -- stays as a no-op alias for the default to avoid breaking
        -- muscle memory from earlier alphas.
        help = "Open diagnostic dump as a copy dialog. `divergence` for source-coverage report; `gold` for per-character gold accounting; `sources` for sibling-source row counts + monthly distribution (alpha18 simulated-import readout — runs a multi-second blocking pass on big TSM CSVs); `chat` to print inline.",
        run = function(rest)
          local sub = rest and rest:lower() or ""
          if sub == "divergence" then divergenceCopyDialog()
          elseif sub == "gold" then goldCopyDialog()
          elseif sub == "sources" then sourcesCopyDialog()
          elseif sub == "chat" then diagPrintChat()
          else diagOpenCopyDialog() end
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
