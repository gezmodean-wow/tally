-- Tally — UI/SetupWizard.lua
--
-- First-run wizard: introduces Tally's data model, exposes the sources
-- we'll pull from, lets users opt in/out per source, and kicks off a
-- chunked initial backfill that doesn't tank framerate while it runs.
--
-- TLY-25. Built atop cw:CreateWizard (Cogworks v0.11.0).
--
-- Trigger: shown automatically on the first PLAYER_LOGIN where
-- TallyDB.inventoryRollup is missing AND any sibling source is detected,
-- OR manually from Settings → "Re-run setup".
--
-- Steps:
--   1. Welcome — what Tally is
--   2. Source detection — live row counts per registered source
--   3. Concept primer — net vs owned vs warband, live values
--   4. Strategy picker — bag valued under 4 presets
--   5. History config — cadence/retention sliders + estimated SV size
--   6. Backfill kickoff — pace selector (gentle / aggressive) + Start
--
-- After Finish: closes the wizard, opens the progress widget, runs
-- Ledger:ImportFromAllSourcesChunked.

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

local function formatGold(copper) return ns.NetWorth.FormatGold(copper or 0) end

local function formatGoldShort(copper)
  copper = math.floor(copper or 0)
  local gold = math.floor(copper / 10000)
  if gold >= 1000000 then return string.format("%.1fM|cffffd700g|r", gold / 1000000)
  elseif gold >= 1000 then return string.format("%.1fk|cffffd700g|r", gold / 1000) end
  return formatGold(copper)
end

-- ============================================================================
-- Wizard state (shared across step builders)
-- ============================================================================

local function makeState()
  local sources = {}
  if ns.Ledger and ns.Ledger.GetSources then
    for _, s in ipairs(ns.Ledger:GetSources()) do
      sources[s.name] = { enabled = true, name = s.name, label = s.label }
    end
  end
  return {
    sources = sources,
    strategy = (ns.NetWorth and ns.NetWorth:GetStrategy()) or "DBRegionMarketAvg",
    historyIntervalHours = 12,
    historyRetentionDays = 90,
    pace = "gentle",  -- "gentle" | "balanced" | "aggressive"
  }
end

-- ============================================================================
-- Step builders
-- ============================================================================

local function buildWelcomeStep(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetAllPoints(parent)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -12)
  title:SetText("Welcome to Tally")
  title:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  body:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
  body:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  body:SetJustifyH("LEFT")
  body:SetJustifyV("TOP")
  body:SetSpacing(4)
  body:SetText(
    "Tally is the personal-finance layer of the Cogworks suite — net worth, "
    .. "ledger, and per-item research across every character on every realm "
    .. "you play.\n\n"
    .. "|cffffd070alpha18 reset.|r This release is a structural rewrite "
    .. "that fixes the constant-pool overflow that haunted big-tester "
    .. "accounts. Your previous Tally ledger has been cleared as part of "
    .. "the upgrade. Settings, history snapshots, and net-worth strategy "
    .. "are preserved — only the transaction ledger was wiped.\n\n"
    .. "From this login forward, Tally captures auction-house, vendor, "
    .. "mail, and repair events live as they happen — Research, Lifecycle, "
    .. "and Compare will be empty until enough data accumulates. Sibling-"
    .. "source import (TSM, FlipQueue, Journalator) returns in alpha19 as "
    .. "a user-initiated, pausable flow.\n\n"
    .. "Click Next to set your pricing strategy and history cadence, or "
    .. "Cancel to skip — you can re-run this any time from Settings.")

  return f
end

local function buildStrategyStep(parent, state)
  local f = CreateFrame("Frame", nil, parent)
  f:SetAllPoints(parent)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -12)
  title:SetText("Pricing strategy")
  title:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local intro = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  intro:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  intro:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  intro:SetJustifyH("LEFT")
  intro:SetSpacing(2)
  intro:SetText("Tally values your inventory under one TSM expression. "
    .. "Different strategies give different headline numbers — that's why "
    .. "Tally and TSM's main UI sometimes disagree. Pick the one that "
    .. "matches how you actually think about your wealth.")

  local presets = {
    "DBRegionMarketAvg",
    "DBMarket",
    "DBMinBuyout",
    "DBHistorical",
  }

  local rowHost = CreateFrame("Frame", nil, f)
  rowHost:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -12)
  rowHost:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  rowHost:SetHeight(#presets * 26 + 4)

  local function valueUnder(strategyExpr)
    -- Re-run a NetWorth:Snapshot but with a temporary strategy. The
    -- Snapshot reads the persisted strategy via NetWorth:GetStrategy(); we
    -- swap, compute, swap back.
    local prev = ns.NetWorth:GetStrategy()
    ns.NetWorth:SetStrategy(strategyExpr)
    local snap = ns.NetWorth:Snapshot()
    ns.NetWorth:SetStrategy(prev)
    return snap.total
  end

  local radios = {}
  for i, expr in ipairs(presets) do
    local row = CreateFrame("Frame", nil, rowHost)
    row:SetPoint("TOPLEFT", rowHost, "TOPLEFT", 0, -((i - 1) * 26))
    row:SetPoint("RIGHT", rowHost, "RIGHT", 0, 0)
    row:SetHeight(24)

    local rb = CreateFrame("CheckButton", nil, row, "UIRadioButtonTemplate")
    rb:SetSize(18, 18)
    rb:SetPoint("LEFT", row, "LEFT", 0, 0)
    rb:SetChecked(expr == state.strategy)
    radios[#radios + 1] = { rb = rb, expr = expr }

    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", rb, "RIGHT", 4, 0)
    lbl:SetWidth(160)
    lbl:SetJustifyH("LEFT")
    lbl:SetText(expr)

    local val = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    val:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    val:SetWidth(180)
    val:SetJustifyH("LEFT")
    if ns.Pricing and ns.Pricing:HasTSM() then
      local copper = valueUnder(expr)
      -- Plain ASCII arrow — one tester reported the "→" (U+2192) glyph
      -- rendered as a missing-character box on their fonts/locale.
      val:SetText("=> " .. formatGoldShort(copper))
      val:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))
    else
      val:SetText("(TSM not detected)")
      val:SetTextColor(themeColor("textDim", { 0.6, 0.6, 0.6, 1 }))
    end

    rb:SetScript("OnClick", function(self)
      state.strategy = expr
      for _, r in ipairs(radios) do
        r.rb:SetChecked(r.expr == expr)
      end
    end)
  end

  local note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("TOPLEFT", rowHost, "BOTTOMLEFT", 0, -16)
  note:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  note:SetJustifyH("LEFT")
  note:SetSpacing(3)
  note:SetText("|cff999999You can change this any time from Settings, or "
    .. "set a custom expression like `min(DBMarket, DBRegionMarketAvg)`.|r")

  return f
end

local function buildHistoryStep(parent, state)
  local f = CreateFrame("Frame", nil, parent)
  f:SetAllPoints(parent)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -12)
  title:SetText("History cadence")
  title:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local intro = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  intro:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  intro:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  intro:SetJustifyH("LEFT")
  intro:SetSpacing(2)
  intro:SetText("Tally takes periodic snapshots of your inventory + prices "
    .. "so it can replay net worth at any past time. Defaults are tuned for "
    .. "heavy users (90k-row ledgers, 700M+ gold) — you can extend retention "
    .. "later from Settings if you want longer history.")

  local function makeIntInput(label, suffix, getter, setter, anchor, anchorPt, gap)
    local row = CreateFrame("Frame", nil, f)
    row:SetPoint("TOPLEFT", anchor, anchorPt, 0, -gap)
    row:SetPoint("RIGHT", f, "RIGHT", -12, 0)
    row:SetHeight(24)

    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", row, "LEFT", 0, 0)
    lbl:SetWidth(140)
    lbl:SetJustifyH("LEFT")
    lbl:SetText(label)

    local edit = CreateFrame("EditBox", nil, row, "BackdropTemplate")
    edit:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
    edit:SetSize(60, 22)
    edit:SetAutoFocus(false)
    edit:SetFontObject("GameFontHighlight")
    edit:SetTextInsets(6, 6, 0, 0)
    edit:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      edgeSize = 1,
    })
    edit:SetBackdropColor(themeColor("bgDark", { 0.04, 0.04, 0.07, 1 }))
    edit:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))
    edit:SetText(tostring(getter()))
    edit:SetScript("OnEnterPressed", function(self)
      local n = tonumber(self:GetText())
      if n and n > 0 then setter(n) end
      self:ClearFocus()
    end)
    edit:SetScript("OnEditFocusLost", function(self)
      local n = tonumber(self:GetText())
      if n and n > 0 then setter(n)
      else self:SetText(tostring(getter())) end
    end)

    local suf = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    suf:SetPoint("LEFT", edit, "RIGHT", 6, 0)
    suf:SetText(suffix)

    return row
  end

  local intervalRow = makeIntInput("Snapshot interval", "hours",
    function() return state.historyIntervalHours end,
    function(n) state.historyIntervalHours = n end,
    intro, "BOTTOMLEFT", 16)

  local retentionRow = makeIntInput("Retention", "days",
    function() return state.historyRetentionDays end,
    function(n) state.historyRetentionDays = n end,
    intervalRow, "BOTTOMLEFT", 6)

  local note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("TOPLEFT", retentionRow, "BOTTOMLEFT", 0, -16)
  note:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  note:SetJustifyH("LEFT")
  note:SetSpacing(3)
  note:SetText("Defaults of 12h / 90d give you ~14 hi-fi snapshots plus "
    .. "~83 daily-rollup snapshots. Snapshots older than 7 days collapse "
    .. "to one-per-day so the saved-variables file stays bounded.")

  return f
end

-- ============================================================================
-- Apply state on Finish
-- ============================================================================

local function applyState(state)
  -- Strategy
  if state.strategy and ns.NetWorth then
    ns.NetWorth:SetStrategy(state.strategy)
  end

  -- History config
  if ns.History then
    if state.historyIntervalHours then
      ns.History:SetInterval(state.historyIntervalHours * 3600)
    end
    if state.historyRetentionDays then
      ns.History:SetRetention(state.historyRetentionDays * 86400)
    end
  end

  -- Disabled-source list persisted so Settings reflects the choice and
  -- ImportFromSource respects it. We don't actually unregister sources —
  -- the user can toggle them back on later.
  TallyDB.disabledSources = TallyDB.disabledSources or {}
  for name, info in pairs(state.sources) do
    TallyDB.disabledSources[name] = (not info.enabled) and true or nil
  end
end

local function finishSetup()
  -- alpha18 active-only baseline: Finish does NOT trigger any sibling-
  -- source backfill. Native captures live from PLAYER_LOGIN forward;
  -- sibling import returns in alpha19 as a user-initiated, pausable flow.
  TallyDB.setup = TallyDB.setup or {}
  TallyDB.setup.completed   = true
  TallyDB.setup.completedAt = time()
  TallyDB.setup.grandfathered = nil
  TallyDB.setup.skipped       = nil
  TallyDB.setup.skippedAt     = nil
  TallyCharDB = TallyCharDB or {}
  TallyCharDB.tallyAcknowledged = true
  if ns.RefreshLDB then pcall(ns.RefreshLDB) end
  if ns.Output then
    ns.Output:Success("Setup complete. Tally is now capturing auction-house, vendor, mail, and repair events live.")
  end
end

-- ============================================================================
-- Wizard frame
-- ============================================================================

-- Singleton: only one wizard instance at a time. Re-shown on demand.
-- Cleared by ResetSetupWizard() so /tally reset gets a fresh state
-- (otherwise the user lands on the same checkbox / radio choices they
-- already made before the reset).
local wizardFrame, wizardWidget

local function createWizardFrame()
  if wizardFrame then return wizardFrame end

  local cw = getCogworks()
  if not (cw and cw.CreateWizard) then
    print("|cffff4040Tally:|r setup wizard requires Cogworks v0.11.0+. "
      .. "Update Cogworks-1.0 to get the wizard primitive.")
    return nil
  end

  -- No global frame name — letting the previous frame fall out of scope
  -- on ResetSetupWizard means a new instance can be built without
  -- colliding on the WoW global namespace.
  wizardFrame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
  wizardFrame:SetSize(640, 480)
  wizardFrame:SetPoint("CENTER")
  wizardFrame:SetFrameStrata("DIALOG")
  wizardFrame:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 },
  })
  wizardFrame:SetBackdropColor(themeColor("bg", { 0.08, 0.08, 0.12, 0.95 }))
  wizardFrame:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))
  wizardFrame:SetMovable(true)
  wizardFrame:EnableMouse(true)
  wizardFrame:RegisterForDrag("LeftButton")
  wizardFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  wizardFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  wizardFrame:Hide()

  local state = makeState()

  wizardWidget = cw:CreateWizard(wizardFrame, {
    steps = {
      { key = "welcome",  title = "Welcome",          build = function(parent) return buildWelcomeStep(parent) end },
      { key = "strategy", title = "Pricing Strategy", build = function(parent) return buildStrategyStep(parent, state) end },
      { key = "history",  title = "History",          build = function(parent) return buildHistoryStep(parent, state) end },
    },
    finishLabel = "Finish",
    onComplete = function()
      applyState(state)
      wizardFrame:Hide()
      finishSetup()
    end,
    onStepChange = function(_, idx)
      -- TLY-35: the moment the player chooses to move forward (clicks Next
      -- past the welcome step), latch setup.skipped so a mid-flow bail
      -- doesn't re-pop on the next character. completed=true (set on
      -- Finish) takes priority in the gate, so this is harmless if the
      -- player goes the distance.
      if idx > 1 then
        TallyDB = TallyDB or {}
        TallyDB.setup = TallyDB.setup or {}
        if not TallyDB.setup.completed and not TallyDB.setup.skipped then
          TallyDB.setup.skipped = true
          TallyDB.setup.skippedAt = time()
        end
        -- TLY-32 / TLY-35 follow-up: per-character marker survives even
        -- when account-wide TallyDB fails to load (constant-table overflow
        -- on huge SVs). See ShouldShowSetupWizard for the OR-gate.
        TallyCharDB = TallyCharDB or {}
        TallyCharDB.tallyAcknowledged = true
      end
    end,
    onCancel = function()
      -- TLY-35: any Cancel from anywhere in the wizard means "I'm done with
      -- this popup." Latch skipped unconditionally so the popup never
      -- re-fires on this account; player re-engages from Settings.
      --
      -- TLY-32 / TLY-35 follow-up: write the persistence flags FIRST,
      -- before any potentially-throwing call (print, RefreshLDB, Hide).
      -- A late error inside this handler used to leave the flags unset
      -- and the popup re-fired on the next session.
      TallyDB = TallyDB or {}
      TallyDB.setup = TallyDB.setup or {}
      TallyCharDB = TallyCharDB or {}
      TallyCharDB.tallyAcknowledged = true
      if not TallyDB.setup.completed then
        TallyDB.setup.skipped = true
        TallyDB.setup.skippedAt = time()
      end
      if ns.Output then
        pcall(ns.Output.Info, ns.Output,
          "Setup skipped. Re-run any time from Settings → Re-run setup wizard.")
      end
      if ns.RefreshLDB then pcall(ns.RefreshLDB) end
      pcall(function() wizardFrame:Hide() end)
    end,
  })
  wizardWidget:SetAllPoints(wizardFrame)

  return wizardFrame
end

-- ============================================================================
-- Public API
-- ============================================================================

function ns.UI.ShowSetupWizard()
  local frame = createWizardFrame()
  if frame then frame:Show() end
end

-- Clear the singleton so the next ShowSetupWizard rebuilds from scratch
-- with a fresh state table. Used by /tally reset — the user's previous
-- source-checkbox choices, strategy radio, and pace selection should
-- not carry over into the next wizard run.
function ns.UI.ResetSetupWizard()
  if wizardFrame then
    wizardFrame:Hide()
    wizardFrame:SetParent(nil)
    wizardFrame:ClearAllPoints()
    wizardFrame = nil
    wizardWidget = nil
  end
end

-- Returns true on the first session where the user hasn't completed setup
-- AND a sibling source is detected (Native is always available so we
-- specifically check for non-Native sources). Called from Core.lua's
-- PLAYER_LOGIN handler shortly after Sources are registered.
function ns.UI.ShouldShowSetupWizard()
  TallyDB = TallyDB or {}
  -- Setup-complete (either user finished it, or grandfather flipped it
  -- on for a returning upgrader). Either way, no auto-open.
  if TallyDB.setup and TallyDB.setup.completed then return false end
  -- TLY-35: player dismissed the popup (Cancel from anywhere in the
  -- wizard, or just clicked Next past the welcome step but bailed
  -- mid-flow). Account-wide flag, one-shot — once set, the popup never
  -- auto-fires again. Re-engagement is exclusively via Settings →
  -- Re-run setup wizard or /tally setup.
  if TallyDB.setup and TallyDB.setup.skipped then return false end
  -- TLY-32 / TLY-35 follow-up: per-character acknowledged marker.
  -- Account-wide TallyDB can fail to load on huge SV files (Lua's
  -- "constant table overflow" parse error fires when the single SV
  -- chunk's constant pool exceeds 2^18 entries — easily hit by a tester
  -- with hundreds of thousands of distinct ledger rows). When the load
  -- fails, TallyDB starts each session as an empty {} and the
  -- account-wide skipped flag is gone, so the popup re-fired on every
  -- alt no matter how many times the player Cancel'd. The per-character
  -- TallyCharDB lives in a separate, much smaller SV file that doesn't
  -- hit the overflow, so this marker is the load-failure-resistant
  -- signal that "this player has already seen and dismissed Tally."
  TallyCharDB = TallyCharDB or {}
  if TallyCharDB.tallyAcknowledged then return false end
  -- Fresh install or post-reset: both have an empty ledger and no
  -- setup-complete flag. Auto-open the wizard so the user lands in the
  -- onboarding flow without having to find /tally setup.
  return true
end
