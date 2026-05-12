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
-- Steps (alpha19):
--   1. Welcome           — what Tally is
--   2. Strategy picker   — bag valued under 4 presets
--   3. History cadence   — interval + retention inputs
--   4. Backfill sources  — per-source opt-in + window selector (conditional;
--                          only registered when sibling sources are detected)
--   5. Backfill pace     — pace preset + budget/delay inputs + live estimate
--                          (conditional; companion to step 4)
--
-- After Finish: applies strategy + history config, persists per-source
-- enablement to TallyDB.disabledSources, and (when sibling sources are
-- detected) queues the chunked backfill via the import controller — runs
-- in a detached widget, doesn't block the wizard close.

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

-- Pace presets. Step 5 lets users pick one, then tune budget/delay
-- independently. The radios stay selected as long as state.budgetRows and
-- state.delaySec exactly match a preset; manual edits drop the selection
-- to a "custom" state (no radio checked) so the player knows their numbers
-- are bespoke.
local PACE_PRESETS = {
  { key = "gentle",     label = "Gentle",     budget =  5000, delay = 3.0 },
  { key = "balanced",   label = "Balanced",   budget = 10000, delay = 2.0 },
  { key = "aggressive", label = "Aggressive", budget = 25000, delay = 1.0 },
}

local function presetByKey(key)
  for _, p in ipairs(PACE_PRESETS) do if p.key == key then return p end end
  return PACE_PRESETS[1]
end

local function makeState()
  local sources = {}
  if ns.Ledger and ns.Ledger.GetSources then
    for _, s in ipairs(ns.Ledger:GetSources()) do
      sources[s.name] = { enabled = true, name = s.name, label = s.label }
    end
  end
  local defaultPace = presetByKey("balanced")
  return {
    sources = sources,
    strategy = (ns.NetWorth and ns.NetWorth:GetStrategy()) or "DBRegionMarketAvg",
    historyIntervalHours = 12,
    historyRetentionDays = 90,
    -- Backfill sources & window
    windowMonths = 12,                  -- 1 | 3 | 12 | 0 (all)
    -- Backfill pace (defaults to "balanced" — 10k rows / 2.0s, matching
    -- TLY-71's starting point. Testers tune via the probe data on Step 4.)
    pace          = "balanced",
    budgetRows    = defaultPace.budget,
    delaySec      = defaultPace.delay,
    -- Probe cache. Populated lazily on Step 4 entry — each adapter's
    -- :ProbeMetadata() is O(rows) and we don't want to pay it twice when
    -- the player flips back and forth between steps.
    probes        = nil,                -- { [name] = probe } once computed
  }
end

-- ============================================================================
-- Sibling-source helpers
-- ============================================================================

-- Sibling sources that are loaded + have a probe. Native is excluded; it's
-- event-driven and has no historical rows to backfill. Returns the registry
-- entries in registration order so the wizard renders them in a stable list.
local function detectImportableSources()
  if not (ns.Ledger and ns.Ledger.GetSources) then return {} end
  local out = {}
  for _, s in ipairs(ns.Ledger:GetSources()) do
    if s.name ~= "native" and ns.Ledger:IsSourceAvailable(s.name) then
      out[#out + 1] = s
    end
  end
  return out
end

-- Live count of months touched by the probe's byMonth distribution. Probes
-- only populate byMonth when rows survived the parse, so an empty byMonth
-- is a valid "0 rows" signal.
local function probeMonthCount(probe)
  if type(probe) ~= "table" or type(probe.byMonth) ~= "table" then return 0 end
  local n = 0
  for _ in pairs(probe.byMonth) do n = n + 1 end
  return n
end

local function formatNumber(n)
  if BreakUpLargeNumbers then return BreakUpLargeNumbers(n or 0) end
  return tostring(n or 0)
end

local function formatProbeSummary(probe)
  if type(probe) ~= "table" then return "scanning…" end
  if probe.error then return "(error: " .. tostring(probe.error) .. ")" end
  if not probe.available then return "(not available)" end
  if not probe.count or probe.count == 0 then return "0 rows" end
  if not probe.fromTs or not probe.toTs then
    return formatNumber(probe.count) .. " rows"
  end
  return string.format("%s rows · %s -> %s · %d months",
    formatNumber(probe.count),
    date("%Y-%m", probe.fromTs),
    date("%Y-%m", probe.toTs),
    probeMonthCount(probe))
end

-- Run :ProbeMetadata on each importable source. Block-probes — for a
-- 90k-row TSM CSV this is multi-second on the input thread. Tradeoff is
-- worth taking on a one-time setup flow; if testers complain we yield it
-- per-source via C_Timer.After.
local function runProbes(importable)
  local probes = {}
  for _, s in ipairs(importable) do
    local adapter = ns.Sources and ns.Sources[
      ({ tsm = "TSM", flipqueue = "FlipQueue", journalator = "Journalator" })[s.name]
      or s.name
    ]
    if not adapter or type(adapter.ProbeMetadata) ~= "function" then
      probes[s.name] = { available = false, error = "no probe" }
    else
      local ok, result = pcall(adapter.ProbeMetadata, adapter)
      if not ok then
        probes[s.name] = { available = false, error = tostring(result) }
      else
        probes[s.name] = result
      end
    end
  end
  return probes
end

-- Sum rows from each enabled source's byMonth distribution that fall
-- inside the window. windowMonths == 0 (or nil) means "all history".
local function estimateRows(state, importable)
  if not state.probes then return 0 end
  local windowMonths = state.windowMonths or 0
  local cutoffMonth = nil
  if windowMonths > 0 then
    cutoffMonth = date("%Y-%m", time() - windowMonths * 30 * 86400)
  end
  local total = 0
  for _, s in ipairs(importable) do
    local enabled = state.sources[s.name] and state.sources[s.name].enabled
    local probe   = state.probes[s.name]
    if enabled and probe and probe.available then
      if cutoffMonth and type(probe.byMonth) == "table" then
        for mk, n in pairs(probe.byMonth) do
          if mk >= cutoffMonth then total = total + n end
        end
      else
        total = total + (probe.count or 0)
      end
    end
  end
  return total
end

-- Convert (rows, budget, delay) → estimated wall-clock seconds. Each cycle
-- is `budget` rows + `delay` seconds; on big imports the per-cycle work is
-- dominated by the delay (parse + insert are sub-frame on modern hardware
-- for 10k-row chunks). Returns 0 if rows or budget is zero.
local function estimateSeconds(totalRows, budgetRows, delaySec)
  if totalRows <= 0 or budgetRows <= 0 then return 0 end
  local cycles = math.ceil(totalRows / budgetRows)
  return cycles * (delaySec or 0)
end

local function formatDuration(seconds)
  seconds = math.max(0, math.floor(seconds))
  if seconds < 60 then return seconds .. "s" end
  local m = math.floor(seconds / 60)
  local s = seconds % 60
  if m < 60 then
    if s == 0 then return m .. "m" end
    return string.format("%dm %ds", m, s)
  end
  local h = math.floor(m / 60)
  m = m % 60
  return string.format("%dh %dm", h, m)
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
-- Step 4 — sources & window
-- ============================================================================
--
-- Per-source checkbox row + window radio set. The probe runs once on first
-- entry (blocking; multi-second on big TSM CSVs) and caches into state.probes
-- so re-entries from Previous are instant. Each row's summary text refreshes
-- when state changes elsewhere via the panel:RefreshEstimates closure that
-- Step 5 installs onto state — the only cross-step coupling.

local function buildSourcesStep(parent, state, importable)
  local f = CreateFrame("Frame", nil, parent)
  f:SetAllPoints(parent)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -12)
  title:SetText("Backfill — sources & window")
  title:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local intro = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  intro:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  intro:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  intro:SetJustifyH("LEFT")
  intro:SetSpacing(2)
  intro:SetText("Pull historical transactions from sibling addons. Each "
    .. "source has a read-only metadata probe so you can see how much "
    .. "history is on offer before committing. Toggle the ones you want; "
    .. "pick a window to bound the import. Tally always keeps capturing "
    .. "live regardless of what you import.")

  -- Header row above the source list.
  local sourceHeader = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  sourceHeader:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -14)
  sourceHeader:SetJustifyH("LEFT")
  sourceHeader:SetText("Sources")

  -- Source row stack. Each row gets a checkbox + label + summary FontString.
  -- Summary text initially reads "scanning…"; flips to the probe summary
  -- once runProbes finishes.
  local rowHost = CreateFrame("Frame", nil, f)
  rowHost:SetPoint("TOPLEFT", sourceHeader, "BOTTOMLEFT", 0, -4)
  rowHost:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  rowHost:SetHeight(#importable * 22 + 4)

  local sourceRows = {}
  for i, s in ipairs(importable) do
    local row = CreateFrame("Frame", nil, rowHost)
    row:SetPoint("TOPLEFT", rowHost, "TOPLEFT", 0, -((i - 1) * 22))
    row:SetPoint("RIGHT", rowHost, "RIGHT", 0, 0)
    row:SetHeight(20)

    local cb = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
    cb:SetSize(20, 20)
    cb:SetPoint("LEFT", row, "LEFT", 0, 0)
    local enabled = state.sources[s.name] and state.sources[s.name].enabled
    cb:SetChecked(enabled ~= false)
    cb:SetScript("OnClick", function(self)
      state.sources[s.name] = state.sources[s.name] or { name = s.name, label = s.label }
      state.sources[s.name].enabled = self:GetChecked() and true or false
      if state.refreshEstimate then state.refreshEstimate() end
    end)

    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", cb, "RIGHT", 4, 0)
    lbl:SetWidth(140)
    lbl:SetJustifyH("LEFT")
    lbl:SetText(s.label or s.name)

    local summary = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    summary:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    summary:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    summary:SetJustifyH("LEFT")
    summary:SetWordWrap(false)
    summary:SetText("scanning…")

    sourceRows[s.name] = { cb = cb, summary = summary }
  end

  -- Window selector. Four mutually-exclusive options; default "last 12mo".
  -- 0 means "all history" — sends no cutoff to the import driver.
  local windowHeader = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  windowHeader:SetPoint("TOPLEFT", rowHost, "BOTTOMLEFT", 0, -12)
  windowHeader:SetJustifyH("LEFT")
  windowHeader:SetText("Window")

  local WINDOWS = {
    { months =  1, label = "Last 30 days"  },
    { months =  3, label = "Last 90 days"  },
    { months = 12, label = "Last 12 months" },
    { months =  0, label = "All history"   },
  }

  local windowHost = CreateFrame("Frame", nil, f)
  windowHost:SetPoint("TOPLEFT", windowHeader, "BOTTOMLEFT", 0, -4)
  windowHost:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  windowHost:SetHeight(#WINDOWS * 22 + 4)

  local windowRadios = {}
  for i, w in ipairs(WINDOWS) do
    local row = CreateFrame("Frame", nil, windowHost)
    row:SetPoint("TOPLEFT", windowHost, "TOPLEFT", 0, -((i - 1) * 22))
    row:SetPoint("RIGHT", windowHost, "RIGHT", 0, 0)
    row:SetHeight(20)

    local rb = CreateFrame("CheckButton", nil, row, "UIRadioButtonTemplate")
    rb:SetSize(18, 18)
    rb:SetPoint("LEFT", row, "LEFT", 0, 0)
    rb:SetChecked(w.months == state.windowMonths)
    windowRadios[#windowRadios + 1] = { rb = rb, months = w.months }

    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", rb, "RIGHT", 4, 0)
    lbl:SetWidth(160)
    lbl:SetJustifyH("LEFT")
    lbl:SetText(w.label)

    rb:SetScript("OnClick", function()
      state.windowMonths = w.months
      for _, r in ipairs(windowRadios) do r.rb:SetChecked(r.months == w.months) end
      if state.refreshEstimate then state.refreshEstimate() end
    end)
  end

  -- ---------------------------------------------------------------------
  -- Probe + refresh
  -- ---------------------------------------------------------------------
  -- The probe is the expensive bit; defer until the step is shown so the
  -- earlier steps aren't held up by it. C_Timer.After yields one frame so
  -- the "scanning…" labels render before the block-probe starts.

  local function paintSummaries()
    for _, s in ipairs(importable) do
      local row = sourceRows[s.name]
      if row then
        local probe = state.probes and state.probes[s.name]
        row.summary:SetText(formatProbeSummary(probe))
      end
    end
  end

  f:SetScript("OnShow", function()
    if state.probes then
      paintSummaries()
      return
    end
    if C_Timer and C_Timer.After then
      C_Timer.After(0.05, function()
        state.probes = runProbes(importable)
        paintSummaries()
        if state.refreshEstimate then state.refreshEstimate() end
      end)
    else
      state.probes = runProbes(importable)
      paintSummaries()
    end
  end)

  return f
end

-- ============================================================================
-- Step 5 — pace & start
-- ============================================================================
--
-- Pace preset radios + numeric budget/delay inputs + a live estimate line.
-- Editing budget/delay manually drops the preset selection to no-radio
-- (custom) so players know their numbers are bespoke. The estimate refreshes
-- on every state change via state.refreshEstimate — installed here, called
-- from Step 4 when window/source toggles change row totals.

local function buildPaceStep(parent, state, importable)
  local f = CreateFrame("Frame", nil, parent)
  f:SetAllPoints(parent)

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -12)
  title:SetText("Backfill — pace & start")
  title:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local intro = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  intro:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
  intro:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  intro:SetJustifyH("LEFT")
  intro:SetSpacing(2)
  intro:SetText("Tally walks each source in chunks so the import stays "
    .. "interactive. Pick a preset, or tune the numbers if you know what "
    .. "you want. The import runs as a detached widget after you Finish — "
    .. "pause, resume, or cancel it any time without losing progress.")

  -- Preset radios.
  local presetHeader = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  presetHeader:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -14)
  presetHeader:SetJustifyH("LEFT")
  presetHeader:SetText("Pace")

  local presetHost = CreateFrame("Frame", nil, f)
  presetHost:SetPoint("TOPLEFT", presetHeader, "BOTTOMLEFT", 0, -4)
  presetHost:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  presetHost:SetHeight(#PACE_PRESETS * 22 + 4)

  local presetRadios = {}
  for i, p in ipairs(PACE_PRESETS) do
    local row = CreateFrame("Frame", nil, presetHost)
    row:SetPoint("TOPLEFT", presetHost, "TOPLEFT", 0, -((i - 1) * 22))
    row:SetPoint("RIGHT", presetHost, "RIGHT", 0, 0)
    row:SetHeight(20)

    local rb = CreateFrame("CheckButton", nil, row, "UIRadioButtonTemplate")
    rb:SetSize(18, 18)
    rb:SetPoint("LEFT", row, "LEFT", 0, 0)
    rb:SetChecked(p.key == state.pace)
    presetRadios[#presetRadios + 1] = { rb = rb, preset = p }

    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", rb, "RIGHT", 4, 0)
    lbl:SetWidth(120)
    lbl:SetJustifyH("LEFT")
    lbl:SetText(p.label)

    local detail = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    detail:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    detail:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    detail:SetJustifyH("LEFT")
    detail:SetText(string.format("%s rows / %.1fs", formatNumber(p.budget), p.delay))
  end

  -- Numeric inputs (budget, delay). Re-use the EditBox pattern from the
  -- history step: BackdropTemplate-styled inputs that commit on Enter or
  -- focus loss. Local helper keeps the two rows consistent.
  local function makeNumericRow(label, suffix, getter, setter, anchor, anchorPt, gap, isFloat)
    local row = CreateFrame("Frame", nil, f)
    row:SetPoint("TOPLEFT", anchor, anchorPt, 0, -gap)
    row:SetPoint("RIGHT", f, "RIGHT", -12, 0)
    row:SetHeight(24)

    local lbl = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    lbl:SetPoint("LEFT", row, "LEFT", 0, 0)
    lbl:SetWidth(80)
    lbl:SetJustifyH("LEFT")
    lbl:SetText(label)

    local edit = CreateFrame("EditBox", nil, row, "BackdropTemplate")
    edit:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
    edit:SetSize(70, 22)
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
    local function paint()
      if isFloat then edit:SetText(string.format("%.1f", getter() or 0))
      else            edit:SetText(tostring(math.floor(getter() or 0))) end
    end
    paint()
    edit:SetScript("OnEnterPressed", function(self)
      local n = tonumber(self:GetText())
      if n and n > 0 then setter(n) end
      paint()
      self:ClearFocus()
    end)
    edit:SetScript("OnEditFocusLost", function(self)
      local n = tonumber(self:GetText())
      if n and n > 0 then setter(n) end
      paint()
    end)

    local suf = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    suf:SetPoint("LEFT", edit, "RIGHT", 6, 0)
    suf:SetText(suffix)

    return row, edit, paint
  end

  -- Selecting a preset writes both fields + repaints the inputs.
  local budgetEdit, budgetRepaint, delayEdit, delayRepaint
  for _, r in ipairs(presetRadios) do
    r.rb:SetScript("OnClick", function()
      state.pace       = r.preset.key
      state.budgetRows = r.preset.budget
      state.delaySec   = r.preset.delay
      for _, rr in ipairs(presetRadios) do rr.rb:SetChecked(rr.preset.key == r.preset.key) end
      if budgetRepaint then budgetRepaint() end
      if delayRepaint  then delayRepaint()  end
      if state.refreshEstimate then state.refreshEstimate() end
    end)
  end

  -- Manual edit → flip to "custom" (no radio selected). The value is
  -- already in state by the time the setter callback runs.
  local function dropPresetSelection()
    state.pace = "custom"
    for _, r in ipairs(presetRadios) do r.rb:SetChecked(false) end
  end

  local budgetRow, budgetEditFrame, budgetPaint = makeNumericRow("Budget", "rows / cycle",
    function() return state.budgetRows end,
    function(n)
      state.budgetRows = math.floor(n)
      if state.budgetRows ~= presetByKey(state.pace).budget then dropPresetSelection() end
      if state.refreshEstimate then state.refreshEstimate() end
    end,
    presetHost, "BOTTOMLEFT", 14, false)
  budgetEdit, budgetRepaint = budgetEditFrame, budgetPaint

  local delayRow, delayEditFrame, delayPaint = makeNumericRow("Delay", "seconds between cycles",
    function() return state.delaySec end,
    function(n)
      state.delaySec = n
      if math.abs(state.delaySec - presetByKey(state.pace).delay) > 0.01 then dropPresetSelection() end
      if state.refreshEstimate then state.refreshEstimate() end
    end,
    budgetRow, "BOTTOMLEFT", 6, true)
  delayEdit, delayRepaint = delayEditFrame, delayPaint

  -- Live estimate line. Reads probe data + current pace/window choices and
  -- prints "~3m 20s for 47,000 rows across 2 sources." Refreshed whenever
  -- state changes via state.refreshEstimate (also called once at end of
  -- build for initial paint).
  local estimate = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  estimate:SetPoint("TOPLEFT", delayRow, "BOTTOMLEFT", 0, -16)
  estimate:SetPoint("RIGHT", f, "RIGHT", -12, 0)
  estimate:SetJustifyH("LEFT")
  estimate:SetSpacing(3)
  estimate:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  state.refreshEstimate = function()
    if not state.probes then
      estimate:SetText("Scanning sources…")
      return
    end
    local totalRows = estimateRows(state, importable)
    if totalRows <= 0 then
      estimate:SetText("Nothing to import under the current window + source selection.")
      return
    end
    local sourceCount = 0
    for _, s in ipairs(importable) do
      if state.sources[s.name] and state.sources[s.name].enabled
         and state.probes[s.name] and state.probes[s.name].available then
        sourceCount = sourceCount + 1
      end
    end
    local secs = estimateSeconds(totalRows, state.budgetRows, state.delaySec)
    estimate:SetText(string.format("Estimate: ~%s for %s rows across %d source%s.",
      formatDuration(secs), formatNumber(totalRows), sourceCount, sourceCount == 1 and "" or "s"))
  end
  state.refreshEstimate()

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

  -- Sibling-source detection happens once at wizard creation. Steps 4 + 5
  -- only register when at least one importable sibling adapter is loaded;
  -- a fresh install with no TSM/FlipQueue/Journalator goes straight from
  -- History to Finish with no dead-end backfill steps.
  local importable = detectImportableSources()
  local steps = {
    { key = "welcome",  title = "Welcome",          build = function(parent) return buildWelcomeStep(parent) end },
    { key = "strategy", title = "Pricing Strategy", build = function(parent) return buildStrategyStep(parent, state) end },
    { key = "history",  title = "History",          build = function(parent) return buildHistoryStep(parent, state) end },
  }
  if #importable > 0 then
    steps[#steps + 1] = { key = "sources", title = "Backfill — sources",
                          build = function(parent) return buildSourcesStep(parent, state, importable) end }
    steps[#steps + 1] = { key = "pace",    title = "Backfill — pace",
                          build = function(parent) return buildPaceStep(parent, state, importable) end }
  end

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
