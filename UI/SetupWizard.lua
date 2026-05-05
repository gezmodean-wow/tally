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
    .. "what it'll cost — then backfill in the background so you can "
    .. "play while it runs. After the one-time backfill, Tally captures new "
    .. "events live as they fire.\n\n"
    .. "|cffffd070Click Next to start setup, or Cancel to skip.|r You can "
    .. "re-open this any time from Settings → Re-run setup wizard. Either "
    .. "way, this popup won't appear again.")

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
  intro:SetText("These are the data sources Tally detected. Sibling addons "
    .. "(TSM, FlipQueue, Journalator) are pulled once as a |cffffffffbackfill|r "
    .. "to recover history Tally couldn't have observed. Tally's own native "
    .. "source captures new events live as they happen. Uncheck any sibling "
    .. "you'd rather keep out of Tally's ledger.")

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

    -- Per-source availability hint. We deliberately do NOT call the
    -- adapter's full getEntriesFn just to display a count — TSM's parse
    -- on a 90k-row CSV is multi-second and would freeze the wizard. The
    -- multi-progress widget shows the real count once parse runs at
    -- import time. Cheap O(1) probes only here.
    local count = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    count:SetPoint("LEFT", status, "RIGHT", 8, 0)
    count:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    count:SetJustifyH("LEFT")
    if not available then
      count:SetText("")
    elseif s.name == "tally-native" then
      count:SetText("|cff999999live — captured as events fire|r")
    elseif s.name == "flipqueue" then
      -- O(1) — FlipQueueDB.log is a regular Lua array.
      local n = (_G.FlipQueueDB and _G.FlipQueueDB.log and #_G.FlipQueueDB.log) or 0
      count:SetText(string.format("|cff999999%d events to scan|r", n))
    elseif s.name == "journalator" then
      -- Live-month buckets are O(1) each. Archived-month counts would
      -- require deserialize-and-decompress per month — skip those for
      -- the wizard, just report the archive-month count as a hint.
      local archives = (_G.JOURNALATOR_ARCHIVE_TIMES and #_G.JOURNALATOR_ARCHIVE_TIMES) or 0
      local liveCount = 0
      local logs = _G.Journalator and _G.Journalator.State and _G.Journalator.State.Logs
      if type(logs) == "table" then
        for _, bucket in pairs(logs) do
          if type(bucket) == "table" then liveCount = liveCount + #bucket end
        end
      end
      count:SetText(string.format(
        "|cff999999%d live + %d month%s archived|r",
        liveCount, archives, archives == 1 and "" or "s"))
    elseif s.name == "tsm" then
      -- TSM CSVs are strings; counting by scanning newlines is roughly
      -- O(N) over the byte stream. For 90k rows that's a brief blocking
      -- pass — acceptable since the user just clicked "Next" to get
      -- here, but let's stay friendly and show "data available" without
      -- the precise number. Real count appears in the per-source bar.
      count:SetText("|cff999999data available — count at import|r")
    else
      count:SetText("")
    end
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
  intro:SetText("Click Finish to start the backfill. Tally will pull history "
    .. "from each sibling source in the background — you'll see a small "
    .. "progress bar bottom-right. Pick how aggressive that should be:")

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
  note:SetText("|cff999999This is a one-time backfill. After it completes, "
    .. "Tally captures new events live via the native source (mailbox, "
    .. "vendor, repair, posting). Sibling adapters won't auto-rerun on a "
    .. "ticker — use Settings → Import now to manually backfill again, "
    .. "or /tally diag divergence to check whether anything Native missed.|r")

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

  -- Build the per-source widget BEFORE flipping setup.completed. Sources
  -- the user opted out of are excluded from the panel (clean visual);
  -- sources detected as unavailable show a "skipped" state so the user
  -- isn't left wondering why TSM isn't there.
  local sourceList = {}
  if ns.Ledger and ns.Ledger.GetSources then
    for _, s in ipairs(ns.Ledger:GetSources()) do
      sourceList[#sourceList + 1] = { name = s.name, label = s.label }
    end
  end

  local panel = ns.UI.CreateMultiProgress({
    title = "Backfilling your data",
    sources = sourceList,
  })
  panel:Show()
  panel:SetFooter("Pace: " .. (PACE_PRESETS[state.pace] and PACE_PRESETS[state.pace].label or state.pace))

  -- Pre-populate state for sources the user opted out of.
  for _, s in ipairs(sourceList) do
    local sourceState = state.sources[s.name]
    if sourceState and not sourceState.enabled then
      local b = panel:GetBar(s.name)
      if b then b:SetState("skipped") end
    end
  end

  -- Flip the setup gate ON before triggering the chunked import — the
  -- driver respects the gate (we made everything else respect it too,
  -- so this single flag is the difference between "import" and "no-op").
  -- We flip BEFORE the chunked driver fires its first onSourceStart.
  TallyDB.setup = TallyDB.setup or {}
  TallyDB.setup.completed = true
  TallyDB.setup.completedAt = time()
  TallyDB.setup.grandfathered = nil
  -- TLY-35: clear the skip-suppression flag once the user actually
  -- finishes setup. ShouldShowSetupWizard short-circuits on completed
  -- before it checks skipped, so this is hygiene rather than load-bearing,
  -- but it keeps the persisted state legible if a future code path ever
  -- inverts the priority.
  TallyDB.setup.skipped = nil
  TallyDB.setup.skippedAt = nil
  -- TLY-32 / TLY-35 follow-up: per-character acknowledged marker. Survives
  -- account-wide TallyDB load failure (constant-table overflow on huge SVs).
  TallyCharDB = TallyCharDB or {}
  TallyCharDB.tallyAcknowledged = true
  if ns.RefreshLDB then pcall(ns.RefreshLDB) end

  ns.Ledger:ImportFromAllSourcesChunked({
    chunkSize = preset.chunkSize,
    delaySec = preset.delaySec,
    sourceDelay = 0.5,
    onSourceSkipped = function(name)
      local b = panel:GetBar(name)
      if b then b:SetState("skipped") end
    end,
    onSourceStart = function(name, label, total)
      local b = panel:GetBar(name)
      if not b then return end
      b:SetState("importing")
      if total and total > 0 then
        b:SetTotal(total)
        b:SetValue(0)
      end
    end,
    onSourceProgress = function(name, inserted, total)
      local b = panel:GetBar(name)
      if b then b:SetValue(inserted) end
    end,
    onSourceDone = function(name, inserted, skipped)
      local b = panel:GetBar(name)
      if b then b:Complete(inserted, skipped) end
      print(string.format("|cff7fbfffTally:|r %s: %d new entries (%d skipped).",
        name, inserted, skipped))
    end,
    onComplete = function(results)
      local total = 0
      for _, r in ipairs(results) do total = total + (r.inserted or 0) end
      panel:Complete(string.format("Backfill complete — %s entries across %d sources.",
        BreakUpLargeNumbers and BreakUpLargeNumbers(total) or tostring(total),
        #results))

      -- Refresh the main UI if it's open so the user immediately sees the new data.
      if ns.UI.MainFrame and ns.UI.MainFrame:IsShown() then
        ns.UI.MainFrame:RefreshActivePage()
      end
      if ns.RefreshLDB then pcall(ns.RefreshLDB) end
    end,
  })
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
      { key = "welcome",  title = "Welcome",       build = function(parent) return buildWelcomeStep(parent) end },
      { key = "sources",  title = "Data Sources",  build = function(parent) return buildSourcesStep(parent, state) end },
      { key = "primer",   title = "Concept Primer", build = function(parent) return buildPrimerStep(parent) end },
      { key = "strategy", title = "Pricing Strategy", build = function(parent) return buildStrategyStep(parent, state) end },
      { key = "history",  title = "History",       build = function(parent) return buildHistoryStep(parent, state) end },
      { key = "backfill", title = "Backfill",      build = function(parent) return buildBackfillStep(parent, state) end },
    },
    finishLabel = "Finish & Backfill",
    onComplete = function()
      applyState(state)
      wizardFrame:Hide()
      startBackfill(state)
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
      pcall(print, "|cff7fbfffTally:|r setup skipped. Re-run any time from Settings → Re-run setup wizard.")
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
