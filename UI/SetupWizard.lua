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

-- Pace presets — chunkSize / delaySec for InsertManyChunked.
local PACE_PRESETS = {
  gentle     = { chunkSize = 200,  delaySec = 0.5,  label = "Gentle (play while it runs)" },
  balanced   = { chunkSize = 500,  delaySec = 0.2,  label = "Balanced" },
  aggressive = { chunkSize = 2000, delaySec = 0.05, label = "Aggressive (AFK while it runs)" },
}

-- ============================================================================
-- Step builders
-- ============================================================================

local function makeBodyText(parent, text)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  fs:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -12)
  fs:SetPoint("RIGHT", parent, "RIGHT", -12, 0)
  fs:SetJustifyH("LEFT")
  fs:SetJustifyV("TOP")
  fs:SetSpacing(4)
  fs:SetText(text)
  return fs
end

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
    .. "|cffffd070Augment, not replace.|r Tally pulls from sibling addons "
    .. "you already use — TSM Accounting, FlipQueue, Journalator — and from "
    .. "Tally's own native event observers. Each source stays fully functional "
    .. "without Tally; installing Tally just unlocks cross-account rollups, "
    .. "pricing-history, and per-item lifecycle analysis.\n\n"
    .. "This wizard takes about a minute. We'll show you what we'll pull and "
    .. "what it'll cost — then start the import in the background so you can "
    .. "play while it runs.")

  return f
end

local function buildSourcesStep(parent, state)
  local f = CreateFrame("Frame", nil, parent)
  f:SetAllPoints(parent)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -12)
  title:SetText("Where your data comes from")
  title:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local intro = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  intro:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  intro:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  intro:SetJustifyH("LEFT")
  intro:SetText("These are the data sources Tally detected. We'll import "
    .. "from every checked source. Uncheck any source you'd rather keep out "
    .. "of Tally's ledger.")

  -- Build a row per registered source.
  local listHost = CreateFrame("Frame", nil, f)
  listHost:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -12)
  listHost:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  listHost:SetHeight(1)

  local sources = (ns.Ledger and ns.Ledger:GetSources()) or {}
  local rowH = 22
  for i, s in ipairs(sources) do
    local row = CreateFrame("Frame", nil, listHost)
    row:SetPoint("TOPLEFT", listHost, "TOPLEFT", 0, -((i - 1) * rowH))
    row:SetPoint("RIGHT", listHost, "RIGHT", 0, 0)
    row:SetHeight(rowH)

    local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    cb:SetSize(20, 20)
    cb:SetPoint("LEFT", row, "LEFT", 0, 0)
    cb:SetChecked(state.sources[s.name] and state.sources[s.name].enabled)
    cb:SetScript("OnClick", function(self)
      state.sources[s.name].enabled = self:GetChecked() and true or false
    end)

    local label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    label:SetWidth(180)
    label:SetJustifyH("LEFT")
    label:SetText(s.label)

    local available = ns.Ledger:IsSourceAvailable(s.name)
    local status = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    status:SetPoint("LEFT", label, "RIGHT", 8, 0)
    status:SetWidth(140)
    status:SetJustifyH("LEFT")
    if available then
      status:SetText("|cff7fffaeAvailable|r")
    else
      status:SetText("|cff888888Not detected — uninstall or check Settings|r")
      cb:SetChecked(false)
      cb:Disable()
      state.sources[s.name].enabled = false
    end

    -- Live row count probe via getEntriesFn if available.
    local count = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    count:SetPoint("LEFT", status, "RIGHT", 8, 0)
    count:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    count:SetJustifyH("LEFT")
    -- Probing the parse can be expensive (TSM 90k rows); only do it if the
    -- source is small or skip with a "(estimated on import)" placeholder.
    -- For TLY-25 first cut, show ledger-already-present count to give a
    -- sense of whether it's already imported.
    local present = #(ns.Ledger:Query({ source = s.name }) or {})
    count:SetText(string.format("%d entries already in ledger", present))
  end
  listHost:SetHeight(math.max(rowH, #sources * rowH))

  local note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("TOPLEFT", listHost, "BOTTOMLEFT", 0, -16)
  note:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  note:SetJustifyH("LEFT")
  note:SetSpacing(2)
  note:SetText("|cff999999Tally never modifies sibling-addon data. Each "
    .. "source's writes stay where they are; we just read.|r")

  return f
end

local function buildPrimerStep(parent)
  local f = CreateFrame("Frame", nil, parent)
  f:SetAllPoints(parent)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -12)
  title:SetText("How Tally segments your wealth")
  title:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  -- Compute live values now so the primer shows real numbers, not abstract
  -- definitions. A user with 700M gold sees their actual segmentation.
  local netSnap = ns.NetWorth:Snapshot()
  local ownedSnap = ns.NetWorth:Snapshot({ includeBound = true })

  local CARD_W = 180
  local PAD = 8
  local LABEL_H, VALUE_H, BODY_GAP = 14, 20, 6

  local function makeCard(anchor, anchorPt, label, value, body)
    local card = CreateFrame("Frame", nil, f, "BackdropTemplate")
    card:SetPoint("TOPLEFT", anchor, anchorPt, 0, -10)
    card:SetWidth(CARD_W)
    card:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      edgeSize = 1,
    })
    card:SetBackdropColor(themeColor("bgDark", { 0.04, 0.04, 0.07, 0.7 }))
    card:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))

    local lbl = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lbl:SetPoint("TOPLEFT", card, "TOPLEFT", PAD, -PAD)
    lbl:SetText(label)

    local val = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    val:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -4)
    val:SetText(value)
    val:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

    -- Body: wrap to card width, measure resulting height, size the card
    -- to fit. WoW renders the FontString into the wrapped layout once
    -- SetText + SetWidth are set; GetStringHeight returns the post-wrap
    -- height. We size the card's height from that so longer text never
    -- clips. All three cards then equalize to the tallest after creation.
    local b = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    b:SetPoint("TOPLEFT", val, "BOTTOMLEFT", 0, -BODY_GAP)
    b:SetWidth(CARD_W - 2 * PAD)
    b:SetJustifyH("LEFT")
    b:SetJustifyV("TOP")
    b:SetWordWrap(true)
    b:SetSpacing(2)
    b:SetText(body)
    card._body = b
    card._fixedTopH = PAD + LABEL_H + 4 + VALUE_H + BODY_GAP

    -- Initial size; equalizeCards (below) bumps every card to the max.
    card:SetHeight(card._fixedTopH + b:GetStringHeight() + PAD)
    return card
  end

  local card1 = makeCard(f, "TOPLEFT", "NET WORTH (saleable)", formatGoldShort(netSnap.total),
    "Items you could actually post on the AH today. Excludes soulbound gear, transmog stash, void storage, and quest items. This is the headline number.")
  card1:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)

  local card2 = makeCard(f, "TOPLEFT", "OWNED WORTH", formatGoldShort(ownedSnap.total),
    "Everything you own, including bound and warbound items. Useful for 'how much wealth do I really have', not for 'how much can I cash out'.")
  card2:SetPoint("TOPLEFT", card1, "TOPRIGHT", 12, 0)

  local card3 = makeCard(f, "TOPLEFT", "WARBAND",
    formatGoldShort(netSnap.warband.total),
    "Gold + items physically in the warbank, plus any warbound items wherever they sit (a Warbound Until Equipped sword in your alt's bags belongs to the warband, not the alt).")
  card3:SetPoint("TOPLEFT", card2, "TOPRIGHT", 12, 0)

  -- Equalize card heights: the tallest body sets the height for all three
  -- so they line up bottom-edge. Bound is always dynamic (depends on the
  -- font + locale + which screen DPI the user has), so we never hard-code.
  local cards = { card1, card2, card3 }
  local maxH = 0
  for _, c in ipairs(cards) do
    if c:GetHeight() > maxH then maxH = c:GetHeight() end
  end
  for _, c in ipairs(cards) do c:SetHeight(maxH) end

  local note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("TOPLEFT", card1, "BOTTOMLEFT", 0, -16)
  note:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  note:SetJustifyH("LEFT")
  note:SetSpacing(3)
  note:SetText("These three views are computed on the same raw data. The "
    .. "Net Worth panel lets you toggle between them. Active AH auctions "
    .. "always count as saleable — they're literally being sold.")

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
      val:SetText("→ " .. formatGoldShort(copper))
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

local function buildBackfillStep(parent, state)
  local f = CreateFrame("Frame", nil, parent)
  f:SetAllPoints(parent)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -12)
  title:SetText("Initial backfill")
  title:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local intro = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  intro:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  intro:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  intro:SetJustifyH("LEFT")
  intro:SetSpacing(2)
  intro:SetText("Click Finish to start the import. Tally will work through "
    .. "your sources in the background — you'll see a small progress bar "
    .. "bottom-right. Pick how aggressive that should be:")

  -- Pace radios.
  local rowHost = CreateFrame("Frame", nil, f)
  rowHost:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -12)
  rowHost:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  rowHost:SetHeight(80)

  local order = { "gentle", "balanced", "aggressive" }
  local radios = {}
  for i, key in ipairs(order) do
    local preset = PACE_PRESETS[key]
    local row = CreateFrame("Frame", nil, rowHost)
    row:SetPoint("TOPLEFT", rowHost, "TOPLEFT", 0, -((i - 1) * 24))
    row:SetPoint("RIGHT", rowHost, "RIGHT", 0, 0)
    row:SetHeight(22)

    local rb = CreateFrame("CheckButton", nil, row, "UIRadioButtonTemplate")
    rb:SetSize(18, 18)
    rb:SetPoint("LEFT", row, "LEFT", 0, 0)
    rb:SetChecked(key == state.pace)
    radios[#radios + 1] = { rb = rb, key = key }

    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", rb, "RIGHT", 4, 0)
    lbl:SetText(string.format("%s — %d rows / tick, %ds gap",
      preset.label, preset.chunkSize, preset.delaySec))

    rb:SetScript("OnClick", function()
      state.pace = key
      for _, r in ipairs(radios) do r.rb:SetChecked(r.key == key) end
    end)
  end

  local note = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  note:SetPoint("TOPLEFT", rowHost, "BOTTOMLEFT", 0, -8)
  note:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  note:SetJustifyH("LEFT")
  note:SetSpacing(3)
  note:SetText("|cff999999After this completes, Tally re-imports every 5 "
    .. "minutes to catch new activity. Native source (your own mailbox "
    .. "scans) is event-driven — it's always live regardless of pace.|r")

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

local function startBackfill(state)
  local preset = PACE_PRESETS[state.pace] or PACE_PRESETS.gentle

  local bar = ns.UI.CreateProgressBar({
    label = "Importing",
    total = 0,  -- unknown until first source reports
  })
  bar:Show()
  bar:Pulse()

  local currentSource = ""
  local currentTotal = 0

  ns.Ledger:ImportFromAllSourcesChunked({
    chunkSize = preset.chunkSize,
    delaySec = preset.delaySec,
    sourceDelay = 0.5,
    onSourceStart = function(name, label, total)
      currentSource = label or name
      currentTotal = total or 0
      bar:SetLabel(string.format("Importing %s", currentSource))
      if currentTotal > 0 then
        bar:SetTotal(currentTotal)
        bar:SetValue(0)
      else
        bar:Pulse()
      end
    end,
    onSourceProgress = function(name, inserted, total)
      bar:SetValue(inserted)
    end,
    onSourceDone = function(name, inserted, skipped)
      print(string.format("|cff7fbfffTally:|r %s: %d new entries (%d skipped).",
        name, inserted, skipped))
    end,
    onComplete = function(results)
      local total = 0
      for _, r in ipairs(results) do total = total + (r.inserted or 0) end
      bar:Complete(string.format("Import complete — %d entries imported.", total))

      -- Mark setup as done so the wizard doesn't auto-run again on next login.
      TallyDB.setup = TallyDB.setup or {}
      TallyDB.setup.completed = true
      TallyDB.setup.completedAt = time()

      -- Refresh the main UI if it's open so the user immediately sees the new data.
      if ns.UI.MainFrame and ns.UI.MainFrame:IsShown() then
        ns.UI.MainFrame:RefreshActivePage()
      end
    end,
  })
end

-- ============================================================================
-- Wizard frame
-- ============================================================================

-- Singleton: only one wizard instance at a time. Re-shown on demand.
local wizardFrame, wizardWidget

local function createWizardFrame()
  if wizardFrame then return wizardFrame end

  local cw = getCogworks()
  if not (cw and cw.CreateWizard) then
    print("|cffff4040Tally:|r setup wizard requires Cogworks v0.11.0+. "
      .. "Update Cogworks-1.0 to get the wizard primitive.")
    return nil
  end

  wizardFrame = CreateFrame("Frame", "TallySetupWizardFrame", UIParent, "BackdropTemplate")
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
      { key = "welcome",  title = "Welcome",       build = buildWelcomeStep },
      { key = "sources",  title = "Data Sources",  build = function(parent) return buildSourcesStep(parent, state) end },
      { key = "primer",   title = "Concept Primer", build = function(parent) return buildPrimerStep(parent) end },
      { key = "strategy", title = "Pricing Strategy", build = function(parent) return buildStrategyStep(parent, state) end },
      { key = "history",  title = "History",       build = function(parent) return buildHistoryStep(parent, state) end },
      { key = "backfill", title = "Backfill",      build = function(parent) return buildBackfillStep(parent, state) end },
    },
    finishLabel = "Finish & Import",
    onComplete = function()
      applyState(state)
      wizardFrame:Hide()
      startBackfill(state)
    end,
    onCancel = function()
      wizardFrame:Hide()
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

-- Returns true on the first session where the user hasn't completed setup
-- AND a sibling source is detected (Native is always available so we
-- specifically check for non-Native sources). Called from Core.lua's
-- PLAYER_LOGIN handler shortly after Sources are registered.
function ns.UI.ShouldShowSetupWizard()
  TallyDB = TallyDB or {}
  if TallyDB.setup and TallyDB.setup.completed then return false end
  if TallyDB.inventoryRollup and TallyDB.inventoryRollup.lastFullScan then
    -- User has data already — they're probably an upgrader. Don't surprise
    -- them with a wizard. They can still re-run from Settings.
    return false
  end
  if not (ns.Ledger and ns.Ledger.GetSources) then return false end
  for _, s in ipairs(ns.Ledger:GetSources()) do
    if s.name ~= "tally-native" and ns.Ledger:IsSourceAvailable(s.name) then
      return true
    end
  end
  return false
end
