-- Tally — UI/SetupWizard.lua
--
-- First-run wizard: introduces Tally's data model and lets the user pick a
-- pricing strategy. Built atop cw:CreateWizard (Cogworks v0.11.0).
--
-- TLY-25, reshaped for the projection-layer redesign (TLY-77/-78). Tally no
-- longer stores a ledger or runs a chunked backfill — it recomputes from
-- sibling sources (TSM, FlipQueue, Journalator) on demand. So the wizard's
-- old Steps 4-5 (source opt-in + backfill pace) are gone; what remains is
-- Welcome + Strategy.
--
-- Trigger: shown automatically on the first PLAYER_LOGIN where setup hasn't
-- been completed/skipped, OR manually from Settings → "Re-run setup".
--
-- Steps:
--   1. Welcome           — what Tally is
--   2. Strategy picker   — bag valued under 4 presets
--
-- After Finish: applies the chosen strategy and marks setup complete.

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
  return {
    strategy = (ns.NetWorth and ns.NetWorth:GetStrategy()) or "DBRegionMarketAvg",
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
    .. "|cffffd070How Tally reads your data.|r Tally doesn't store its own "
    .. "transaction log. Instead it reads your ledger from the addons you "
    .. "already run — TSM Accounting, FlipQueue, Journalator — and merges "
    .. "them into one deduplicated view. Net worth works on its own from "
    .. "Syndicator; the ledger and research light up when sibling addons are "
    .. "present.\n\n"
    .. "The first time you open a detailed view, Tally parses those sources "
    .. "once (a couple of seconds behind a loading bar) and caches the "
    .. "result for the session. Nothing is written that grows with your "
    .. "trade volume, so Tally never bloats your saved-variables.\n\n"
    .. "Click Next to set your pricing strategy, or Cancel to skip — you can "
    .. "re-run this any time from Settings.")

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

-- ============================================================================
-- Apply state on Finish
-- ============================================================================

local function applyState(state)
  if state.strategy and ns.NetWorth then
    ns.NetWorth:SetStrategy(state.strategy)
  end
end

local function finishSetup()
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
    ns.Output:Success("Setup complete. Tally will compute your ledger from your sibling addons on demand.")
  end
end

-- ============================================================================
-- Wizard frame
-- ============================================================================

-- Singleton: only one wizard instance at a time. Re-shown on demand.
-- Cleared by ResetSetupWizard() so /tally reset gets a fresh state.
local wizardFrame, wizardWidget

local function createWizardFrame()
  if wizardFrame then return wizardFrame end

  local cw = getCogworks()
  if not (cw and cw.CreateWizard) then
    if ns.Output then
      ns.Output:Error("Setup wizard requires Cogworks v0.11.0+. Update Cogworks-1.0 to get the wizard primitive.")
    end
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

  local steps = {
    { key = "welcome",  title = "Welcome",          build = function(parent) return buildWelcomeStep(parent) end },
    { key = "strategy", title = "Pricing Strategy", build = function(parent) return buildStrategyStep(parent, state) end },
  }

  wizardWidget = cw:CreateWizard(wizardFrame, {
    steps = steps,
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
        -- when account-wide TallyDB fails to load. See ShouldShowSetupWizard.
        TallyCharDB = TallyCharDB or {}
        TallyCharDB.tallyAcknowledged = true
      end
    end,
    onCancel = function()
      -- TLY-35: any Cancel from anywhere in the wizard means "I'm done with
      -- this popup." Latch skipped unconditionally so the popup never
      -- re-fires on this account; player re-engages from Settings.
      --
      -- Write the persistence flags FIRST, before any potentially-throwing
      -- call (print, RefreshLDB, Hide).
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
-- with a fresh state table. Used by /tally reset.
function ns.UI.ResetSetupWizard()
  if wizardFrame then
    wizardFrame:Hide()
    wizardFrame:SetParent(nil)
    wizardFrame:ClearAllPoints()
    wizardFrame = nil
    wizardWidget = nil
  end
end

-- Returns true on the first session where the user hasn't completed or
-- skipped setup. Called from Core.lua's PLAYER_LOGIN handler.
function ns.UI.ShouldShowSetupWizard()
  TallyDB = TallyDB or {}
  -- Setup-complete (either user finished it, or grandfather flipped it
  -- on for a returning upgrader). Either way, no auto-open.
  if TallyDB.setup and TallyDB.setup.completed then return false end
  -- TLY-35: player dismissed the popup. Account-wide flag, one-shot —
  -- once set, the popup never auto-fires again. Re-engagement is via
  -- Settings → Re-run setup wizard or /tally setup.
  if TallyDB.setup and TallyDB.setup.skipped then return false end
  -- TLY-32 / TLY-35 follow-up: per-character acknowledged marker. The
  -- account-wide TallyDB can fail to load on a corrupt/huge SV file, in
  -- which case the skipped flag is gone; the per-character TallyCharDB
  -- lives in a separate, smaller SV file and is the load-failure-resistant
  -- signal that "this player has already seen and dismissed Tally."
  TallyCharDB = TallyCharDB or {}
  if TallyCharDB.tallyAcknowledged then return false end
  -- Fresh install or post-reset: auto-open the wizard so the user lands in
  -- the onboarding flow without having to find /tally setup.
  return true
end
