-- Tally — UI/SpinePage.lua
--
-- Data-spine verification view (TLY-77 build-out, projection-layer
-- redesign).
--
-- A gated, debug-oriented tab — registered only when
-- TallyDB.ui.showSpineTab is set (Settings toggle), the same pattern as
-- the Compare tab. It exists so testers (and we) can see the unified
-- ledger the spine computes — ParseCache -> Dedup -> Overrides ->
-- UnifiedLedger — and diff it against the live LedgerPage *before* the
-- old store is retired (TLY-78). It is not part of the final navigation
-- (the redesign's Live/Historical/Tools/Settings/Appearance left bar);
-- it is the scaffolding that lets the cutover happen with confidence.
--
-- This is also where the lazy parse is triggered: opening the tab calls
-- ParseCache:Ensure(), which kicks the parse if it has not run this
-- session — and UI/ParseProgress.lua's loading bar fires off the same
-- ParseCache state. A spinner-style status line covers the wait.

local addonName, ns = ...
ns.UI = ns.UI or {}

-- Most-recent records shown in "all" mode. The verification view is for
-- spot-checking, not browsing a full 50k-row ledger; the review list is
-- never capped (every conflict must be visible).
local MAX_ROWS = 1000

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

local function formatGoldShort(copper)
  copper = math.floor(copper or 0)
  local gold = math.floor(copper / 10000)
  if gold >= 1000000 then return string.format("%.1fM|cffffd700g|r", gold / 1000000) end
  if gold >= 1000 then return string.format("%.1fk|cffffd700g|r", gold / 1000) end
  if ns.NetWorth and ns.NetWorth.FormatGold then
    return ns.NetWorth.FormatGold(copper)
  end
  return string.format("%d|cffffd700g|r", gold)
end

local function formatGroup(n)
  if BreakUpLargeNumbers then return BreakUpLargeNumbers(n) end
  return tostring(n)
end

local function formatFlag(v)
  if v == "review"   then return "|cffff6666⚠ review|r" end
  if v == "override" then return "|cff7fffaeoverride|r" end
  return "|cff666666—|r"
end

function ns.UI.CreateSpinePage(parent)
  local page = CreateFrame("Frame", nil, parent)
  local state = { mode = "all" }  -- "all" | "review"

  -- ── Top row ────────────────────────────────────────────────────────────
  local row = CreateFrame("Frame", nil, page)
  row:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
  row:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 0)
  row:SetHeight(36)

  local reparseBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  reparseBtn:SetSize(90, 22)
  reparseBtn:SetPoint("LEFT", row, "LEFT", 0, 0)
  reparseBtn:SetText("Re-parse")

  local reviewCB = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
  reviewCB:SetSize(22, 22)
  reviewCB:SetPoint("LEFT", reparseBtn, "RIGHT", 8, 0)
  reviewCB.text = reviewCB:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  reviewCB.text:SetPoint("LEFT", reviewCB, "RIGHT", 0, 1)
  reviewCB.text:SetText("Flagged for review only")

  local exportBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  exportBtn:SetSize(80, 22)
  exportBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
  exportBtn:SetText("Export")

  -- ── Summary card ───────────────────────────────────────────────────────
  local summary = CreateFrame("Frame", nil, page, "BackdropTemplate")
  summary:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -8)
  summary:SetPoint("TOPRIGHT", row, "BOTTOMRIGHT", 0, -8)
  summary:SetHeight(52)
  summary:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  summary:SetBackdropColor(themeColor("bgDark", { 0.04, 0.04, 0.07, 0.7 }))
  summary:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))

  local sumText = summary:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  sumText:SetPoint("TOPLEFT", summary, "TOPLEFT", 8, -8)
  sumText:SetPoint("BOTTOMRIGHT", summary, "BOTTOMRIGHT", -8, 8)
  sumText:SetJustifyH("LEFT")
  sumText:SetJustifyV("TOP")
  sumText:SetSpacing(2)

  -- ── Table ──────────────────────────────────────────────────────────────
  local cw = getCogworks()
  local tableHost = CreateFrame("Frame", nil, page)
  tableHost:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -8)
  tableHost:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)

  local scrollTable
  if cw and cw.CreateScrollTable then
    scrollTable = cw:CreateScrollTable(tableHost, {
      { key = "atTime", label = "TIME", width = 100, sortable = true,
        format = function(t) return t and date("%m/%d %H:%M", t) or "—" end },
      { key = "char",    label = "CHARACTER", width = 130, sortable = true },
      { key = "realm",   label = "REALM",     width = 90,  sortable = true },
      { key = "kind",    label = "KIND",      width = 80,  sortable = true },
      { key = "item",    label = "ITEM",      width = 70,  sortable = true,
        format = function(v) return (v == 0) and "—" or tostring(v) end },
      { key = "qty",     label = "QTY",       width = 50,  sortable = true, align = "RIGHT" },
      { key = "copper",  label = "AMOUNT",    width = 90,  sortable = true,
        align = "RIGHT", format = formatGoldShort },
      { key = "sources", label = "SOURCES",   width = 130, sortable = true },
      { key = "flag",    label = "FLAG",      width = 80,  sortable = true,
        format = formatFlag },
    })
  else
    local note = tableHost:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", tableHost, "TOPLEFT", 8, -8)
    note:SetText("Scroll-table primitive unavailable — update Cogworks.")
  end

  -- ── Row projection ─────────────────────────────────────────────────────
  -- Flatten a UnifiedLedger record into the table's primitive columns so
  -- the scroll table can sort on them.
  local function projectRow(rec)
    local srcs = {}
    for s in pairs(rec.sources or {}) do srcs[#srcs + 1] = s end
    table.sort(srcs)
    local flag = ""
    if rec.review then flag = "review"
    elseif rec.overridden then flag = "override" end
    return {
      atTime  = rec.atTime or 0,
      char    = rec.charKey or "?",
      realm   = (rec.realm and rec.realm.key) or "?",
      kind    = rec.kind or "?",
      item    = rec.itemID or 0,
      qty     = rec.count or 0,
      copper  = rec.copper or 0,
      sources = table.concat(srcs, "+"),
      flag    = flag,
    }
  end

  local lastRows = {}

  -- ── Refresh ────────────────────────────────────────────────────────────
  function page:Refresh()
    local PC = ns.Spine and ns.Spine.ParseCache
    local UL = ns.Spine and ns.Spine.UnifiedLedger
    if not (PC and UL) then
      sumText:SetText("|cffff6666Spine modules not loaded.|r")
      if scrollTable then scrollTable:SetData({}) end
      lastRows = {}
      return
    end

    if not PC:IsEnabled() then
      sumText:SetText("|cffffd070Spine is disabled.|r  Enable it with |cff7fbfff/tally spine on|r, then re-parse.")
      if scrollTable then scrollTable:SetData({}) end
      lastRows = {}
      return
    end

    if not UL:IsReady() then
      local st = PC:GetState()
      sumText:SetText(string.format(
        "|cff7fbfffParsing sibling sources…|r  (%d / %d)  — watch the loading bar.",
        st.done or 0, st.total or 0))
      if scrollTable then scrollTable:SetData({}) end
      lastRows = {}
      return
    end

    -- Cache is ready — project the unified ledger.
    local records = (state.mode == "review")
      and UL:GetReviewList() or UL:Query()
    local stats = UL:Stats()
    local realmCount = 0
    for _ in pairs(stats.byRealm or {}) do realmCount = realmCount + 1 end

    -- Newest first; "all" mode is capped for responsiveness.
    table.sort(records, function(a, b) return (a.atTime or 0) > (b.atTime or 0) end)
    local capped = false
    if state.mode == "all" and #records > MAX_ROWS then
      capped = true
    end

    local rows = {}
    for i, rec in ipairs(records) do
      if state.mode == "all" and i > MAX_ROWS then break end
      rows[#rows + 1] = projectRow(rec)
    end
    lastRows = rows

    local shownNote = capped
      and string.format("  showing newest %s of %s", formatGroup(MAX_ROWS), formatGroup(#records))
      or  string.format("  showing %s", formatGroup(#rows))
    sumText:SetText(string.format(
      "|cff7fffae%s records|r across %d realm%s  •  |cffff6666%s flagged for review|r  •  %d override%s  •  mode: %s%s",
      formatGroup(stats.count), realmCount, realmCount == 1 and "" or "s",
      formatGroup(stats.review),
      (ns.Spine.Overrides and ns.Spine.Overrides:Count()) or 0,
      ((ns.Spine.Overrides and ns.Spine.Overrides:Count()) or 0) == 1 and "" or "s",
      state.mode == "review" and "flagged-for-review" or "all",
      shownNote))

    if scrollTable then scrollTable:SetData(rows) end
  end

  -- ── Controls ───────────────────────────────────────────────────────────
  reparseBtn:SetScript("OnClick", function()
    local PC = ns.Spine and ns.Spine.ParseCache
    if not PC then return end
    if not PC:IsEnabled() then
      if ns.Output then
        ns.Output:Warn("Spine is disabled — `/tally spine on` to enable.")
      end
      return
    end
    PC:Refresh()  -- re-parse; the page listener repaints when it settles
    page:Refresh()
  end)

  reviewCB:SetScript("OnClick", function(self)
    state.mode = self:GetChecked() and "review" or "all"
    page:Refresh()
  end)

  exportBtn:SetScript("OnClick", function()
    local lines = {}
    local function emit(s) lines[#lines + 1] = s end
    emit("Tally data-spine — " ..
      (state.mode == "review" and "flagged-for-review" or "unified ledger"))
    emit((sumText:GetText() or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
    emit("")
    for _, r in ipairs(lastRows) do
      emit(string.format("%s | %s | %s | %s | item:%s | x%s | %s | %s%s",
        r.atTime and date("%m/%d %H:%M", r.atTime) or "?",
        r.char, r.realm, r.kind, tostring(r.item), tostring(r.qty),
        formatGoldShort(r.copper):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""),
        r.sources,
        r.flag ~= "" and ("  [" .. r.flag .. "]") or ""))
    end
    if ns.Output then
      ns.Output:Inspect(table.concat(lines, "\n"),
        "Tally data-spine readout — paste into a GitHub issue.")
    end
  end)

  -- ── Lifecycle ──────────────────────────────────────────────────────────
  -- Opening the tab is the lazy parse trigger: Ensure kicks ParseCache if
  -- it has not run this session (UI/ParseProgress.lua's bar shows the
  -- wait); the listener below repaints the page when the parse settles.
  page:HookScript("OnShow", function()
    if ns.Spine and ns.Spine.ParseCache then
      ns.Spine.ParseCache:Ensure()
    end
    page:Refresh()
  end)

  if ns.Spine and ns.Spine.ParseCache and ns.Spine.ParseCache.RegisterListener then
    ns.Spine.ParseCache:RegisterListener("spine-page", function(st)
      if page:IsShown() and st and (st.phase == "ready" or st.phase == "error") then
        page:Refresh()
      end
    end)
  end

  page:Refresh()
  return page
end
