-- Tally — UI/LedgerView.lua
--
-- Ledger view (TLY-86) — the unified, deduplicated/merged ledger for the
-- active window, under Live / Historical. Window-aware (:SetWindow).
--
-- Left:  a sortable scroll table of the unified ledger (Spine/UnifiedLedger),
--        scoped to the window and an optional kind filter.
-- Right: per-realm and per-item stats, the operating-cost breakdown, and the
--        source-reconciliation facet — what merged across sources vs what is
--        unique to each (this absorbs the old Compare tab / TLY-24).
--
-- The unified ledger is recompute-on-parse, so opening the view triggers
-- ParseCache:Ensure and a "parsing…" state covers the wait.

local addonName, ns = ...
ns.UI = ns.UI or {}

local MAX_ROWS = 2000

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

local function formatGold(copper)
  if ns.NetWorth and ns.NetWorth.FormatGold then return ns.NetWorth.FormatGold(copper or 0) end
  return tostring(math.floor((copper or 0) / 10000)) .. "g"
end

local function formatGoldShort(copper)
  copper = math.floor(copper or 0)
  local neg = copper < 0
  local g = math.abs(copper) / 10000
  local s
  if g >= 1000000 then s = string.format("%.1fM", g / 1000000)
  elseif g >= 1000 then s = string.format("%.1fk", g / 1000)
  else s = string.format("%d", g) end
  return (neg and "-" or "") .. s .. "|cffffd700g|r"
end

local function formatGroup(n)
  if BreakUpLargeNumbers then return BreakUpLargeNumbers(n) end
  return tostring(n)
end

local function itemName(itemID)
  if not itemID or itemID == 0 then return "(no item)" end
  local name = GetItemInfo and GetItemInfo(itemID)
  return name or ("item:" .. tostring(itemID))
end

local function formatFlag(v)
  if v == "review"   then return "|cffff6666⚠ review|r" end
  if v == "override" then return "|cff7fffaeoverride|r" end
  return "|cff666666—|r"
end

-- Kind filter presets. nil `kinds` = all.
local FILTERS = {
  { key = "all",       label = "All",       kinds = nil },
  { key = "sales",     label = "Sales",     kinds = { "sale", "vendor-sell" } },
  { key = "purchases", label = "Purchases", kinds = { "purchase", "vendor-buy" } },
  { key = "costs",     label = "Costs",     kinds = { "ah-fee", "ah-deposit", "repair" } },
}

local SELL_KINDS = { sale = true, ["vendor-sell"] = true }
local BUY_KINDS  = { purchase = true, ["vendor-buy"] = true }
local COST_BUCKET = { ["ah-fee"] = "ahCut", ["ah-deposit"] = "deposits", repair = "repairs" }

-- Single pass over the windowed unified ledger producing every right-hand
-- stat: per-realm, per-item, operating cost, and source reconciliation.
local function foldStats(records)
  local realms = {}   -- rk -> { count, buy, sell }
  local items  = {}   -- itemID -> { sold, bought, qtySold }
  local cost   = { ahCut = 0, deposits = 0, repairs = 0, other = 0, total = 0 }
  local srcCount = {} -- source -> records contributed
  local uniq     = {} -- source -> records unique to that source
  local merged = 0    -- records contributed to by >1 source

  for _, rec in ipairs(records) do
    local kind, copper, count = rec.kind, rec.copper or 0, rec.count or 0

    local rk = (rec.realm and rec.realm.key) or "?"
    local r = realms[rk]
    if not r then r = { count = 0, buy = 0, sell = 0 }; realms[rk] = r end
    r.count = r.count + 1
    if SELL_KINDS[kind] then r.sell = r.sell + copper
    elseif BUY_KINDS[kind] then r.buy = r.buy + copper end

    if rec.itemID then
      local it = items[rec.itemID]
      if not it then it = { sold = 0, bought = 0, qtySold = 0 }; items[rec.itemID] = it end
      if SELL_KINDS[kind] then it.sold = it.sold + copper; it.qtySold = it.qtySold + count
      elseif BUY_KINDS[kind] then it.bought = it.bought + copper end
    end

    local bucket = COST_BUCKET[kind]
    if bucket then cost[bucket] = cost[bucket] + copper end

    local srcs, nsrc = rec.sources or {}, 0
    for s in pairs(srcs) do
      nsrc = nsrc + 1
      srcCount[s] = (srcCount[s] or 0) + 1
    end
    if nsrc > 1 then merged = merged + 1
    elseif nsrc == 1 then
      local only = next(srcs)
      uniq[only] = (uniq[only] or 0) + 1
    end
  end
  cost.total = cost.ahCut + cost.deposits + cost.repairs + cost.other

  return { realms = realms, items = items, cost = cost,
           srcCount = srcCount, uniq = uniq, merged = merged }
end

local function topN(map, valueFn, n)
  local list = {}
  for k, v in pairs(map) do list[#list + 1] = { key = k, v = v } end
  table.sort(list, function(a, b) return valueFn(a.v) > valueFn(b.v) end)
  local out = {}
  for i = 1, math.min(n, #list) do out[i] = list[i] end
  return out, #list
end

function ns.UI.CreateLedgerView(parent)
  local page = CreateFrame("Frame", nil, parent)
  local win = { from = 0, to = nil, label = "Live" }
  local filterKey = "all"
  local reviewOnly = false

  -- ── Header ───────────────────────────────────────────────────────────────
  local header = CreateFrame("Frame", nil, page)
  header:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
  header:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 0)
  header:SetHeight(26)

  local winLabel = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  winLabel:SetPoint("LEFT", header, "LEFT", 2, 0)
  winLabel:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local exportBtn = CreateFrame("Button", nil, header, "UIPanelButtonTemplate")
  exportBtn:SetSize(70, 22)
  exportBtn:SetPoint("RIGHT", header, "RIGHT", 0, 0)
  exportBtn:SetText("Export")

  local reviewCB = CreateFrame("CheckButton", nil, header, "UICheckButtonTemplate")
  reviewCB:SetSize(22, 22)
  reviewCB:SetPoint("RIGHT", exportBtn, "LEFT", -6, 0)
  reviewCB.text = reviewCB:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  reviewCB.text:SetPoint("RIGHT", reviewCB, "LEFT", -2, 1)
  reviewCB.text:SetText("Review only")
  reviewCB.text:SetJustifyH("RIGHT")

  -- Filter buttons.
  local filterBtns = {}
  local fx = 0
  local filterHost = CreateFrame("Frame", nil, header)
  filterHost:SetPoint("LEFT", winLabel, "RIGHT", 16, 0)
  filterHost:SetSize(360, 22)
  for _, f in ipairs(FILTERS) do
    local b = CreateFrame("Button", nil, filterHost, "UIPanelButtonTemplate")
    b:SetSize(78, 20)
    b:SetPoint("LEFT", filterHost, "LEFT", fx, 0)
    b:SetText(f.label)
    b.fkey = f.key
    b:SetScript("OnClick", function() filterKey = f.key; page:Refresh() end)
    filterBtns[#filterBtns + 1] = b
    fx = fx + 82
  end

  -- ── Summary line ─────────────────────────────────────────────────────────
  local summary = page:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  summary:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 2, -6)
  summary:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -2, -6)
  summary:SetJustifyH("LEFT")

  -- ── Body split: table (left) + stats report (right) ──────────────────────
  local body = CreateFrame("Frame", nil, page)
  body:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -8)
  body:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)

  local tableHost = CreateFrame("Frame", nil, body)
  tableHost:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
  tableHost:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
  tableHost:SetWidth(1) -- set in layout

  local statsPanel = CreateFrame("Frame", nil, body, "BackdropTemplate")
  statsPanel:SetPoint("TOPRIGHT", body, "TOPRIGHT", 0, 0)
  statsPanel:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", 0, 0)
  statsPanel:SetWidth(300)
  statsPanel:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
  })
  statsPanel:SetBackdropColor(themeColor("bgDark", { 0.04, 0.04, 0.07, 0.5 }))
  statsPanel:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))

  local statsText = statsPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  statsText:SetPoint("TOPLEFT", statsPanel, "TOPLEFT", 8, -8)
  statsText:SetPoint("BOTTOMRIGHT", statsPanel, "BOTTOMRIGHT", -8, 8)
  statsText:SetJustifyH("LEFT")
  statsText:SetJustifyV("TOP")
  statsText:SetSpacing(2)

  -- Keep the table host filling the space left of the (fixed-width) panel.
  local function layout()
    local w = body:GetWidth()
    if w <= 0 then return end
    local panelW = math.min(320, math.max(240, w * 0.34))
    statsPanel:SetWidth(panelW)
    tableHost:ClearAllPoints()
    tableHost:SetPoint("TOPLEFT", body, "TOPLEFT", 0, 0)
    tableHost:SetPoint("BOTTOMLEFT", body, "BOTTOMLEFT", 0, 0)
    tableHost:SetPoint("RIGHT", statsPanel, "LEFT", -8, 0)
  end
  body:SetScript("OnSizeChanged", layout)

  -- ── Scroll table ─────────────────────────────────────────────────────────
  local cw = getCogworks()
  local scrollTable
  if cw and cw.CreateScrollTable then
    scrollTable = cw:CreateScrollTable(tableHost, {
      { key = "atTime", label = "TIME", width = 96, sortable = true,
        format = function(t) return t and date("%m/%d %H:%M", t) or "—" end },
      { key = "char",   label = "CHARACTER", width = 120, sortable = true },
      { key = "realm",  label = "REALM",     width = 80,  sortable = true },
      { key = "kind",   label = "KIND",      width = 78,  sortable = true },
      { key = "itemName", label = "ITEM",    width = 150, sortable = true },
      { key = "qty",    label = "QTY",       width = 44,  sortable = true, align = "RIGHT" },
      { key = "copper", label = "AMOUNT",    width = 84,  sortable = true,
        align = "RIGHT", format = formatGoldShort },
      { key = "sources", label = "SOURCES",  width = 116, sortable = true },
      { key = "flag",   label = "FLAG",      width = 70,  sortable = true, format = formatFlag },
    })
  else
    local note = tableHost:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", tableHost, "TOPLEFT", 8, -8)
    note:SetText("Scroll-table primitive unavailable — update Cogworks.")
  end

  local function projectRow(rec)
    local srcs = {}
    for s in pairs(rec.sources or {}) do srcs[#srcs + 1] = s end
    table.sort(srcs)
    local flag = ""
    if rec.review then flag = "review" elseif rec.overridden then flag = "override" end
    return {
      atTime   = rec.atTime or 0,
      char     = rec.charKey or "?",
      realm    = (rec.realm and rec.realm.key) or "?",
      kind     = rec.kind or "?",
      itemName = itemName(rec.itemID),
      qty      = rec.count or 0,
      copper   = rec.copper or 0,
      sources  = table.concat(srcs, "+"),
      flag     = flag,
    }
  end

  local lastRows = {}

  -- ── Stats report (right panel) ───────────────────────────────────────────
  local function renderStats(allRecords, stats)
    local L = {}
    local function emit(s) L[#L + 1] = s end

    -- Per-realm (top by record count).
    emit("|cffffd070PER REALM|r")
    local realms, realmTotal = topN(stats.realms, function(v) return v.count end, 6)
    if #realms == 0 then emit("  (none)") end
    for _, e in ipairs(realms) do
      emit(string.format("  %s  |cff888888%s rec|r  |cff66dd66%s|r/|cffdd6666%s|r",
        e.key, formatGroup(e.v.count), formatGoldShort(e.v.sell), formatGoldShort(e.v.buy)))
    end
    if realmTotal > #realms then emit(string.format("  |cff666666…+%d more|r", realmTotal - #realms)) end
    emit(" ")

    -- Per-item (top by gross sold).
    emit("|cffffd070TOP PRODUCTS (by sold)|r")
    local items, itemTotal = topN(stats.items, function(v) return v.sold end, 6)
    local anyItems = false
    for _, e in ipairs(items) do
      if e.v.sold > 0 then
        anyItems = true
        emit(string.format("  %s  |cff66dd66%s|r |cff888888x%s|r",
          itemName(e.key), formatGoldShort(e.v.sold), formatGroup(e.v.qtySold)))
      end
    end
    if not anyItems then emit("  (no sales in window)") end
    if itemTotal > #items then emit(string.format("  |cff666666…+%d more|r", itemTotal - #items)) end
    emit(" ")

    -- Operating cost.
    emit("|cffffd070OPERATING COST|r")
    emit(string.format("  Total:    %s", formatGoldShort(stats.cost.total)))
    emit(string.format("  AH cut:   %s", formatGoldShort(stats.cost.ahCut)))
    emit(string.format("  Deposits: %s", formatGoldShort(stats.cost.deposits)))
    emit(string.format("  Repairs:  %s", formatGoldShort(stats.cost.repairs)))
    if stats.cost.other > 0 then emit(string.format("  Other:    %s", formatGoldShort(stats.cost.other))) end
    emit(" ")

    -- Source reconciliation (absorbs the old Compare tab / TLY-24).
    emit("|cffffd070SOURCE RECONCILIATION|r")
    local total = #allRecords
    emit(string.format("  %s unified records", formatGroup(total)))
    emit(string.format("  |cff7fffae%s merged|r (seen by 2+ sources)", formatGroup(stats.merged)))
    local srcs = {}
    for s in pairs(stats.srcCount) do srcs[#srcs + 1] = s end
    table.sort(srcs)
    for _, s in ipairs(srcs) do
      emit(string.format("  %s: %s rec  |cff888888(%s unique)|r",
        s, formatGroup(stats.srcCount[s]), formatGroup(stats.uniq[s] or 0)))
    end
    if #srcs == 0 then emit("  (no sources parsed)") end

    statsText:SetText(table.concat(L, "\n"))
  end

  -- ── Refresh ───────────────────────────────────────────────────────────────
  function page:SetWindow(from, to, label)
    win.from, win.to, win.label = from or 0, to, label or "Live"
  end

  function page:Refresh()
    winLabel:SetText("Ledger — " .. (win.label or "Live"))
    for _, b in ipairs(filterBtns) do
      b:SetNormalFontObject(b.fkey == filterKey and "GameFontNormalSmall" or "GameFontDisableSmall")
    end
    reviewCB:SetChecked(reviewOnly)

    local UL = ns.Spine and ns.Spine.UnifiedLedger
    if not (UL and UL.IsReady) then
      summary:SetText("|cffff6666Spine not loaded.|r")
      if scrollTable then scrollTable:SetData({}) end
      statsText:SetText("")
      layout()
      return
    end
    if not UL:IsReady() then
      local PC = ns.Spine.ParseCache
      local st = PC and PC:GetState() or {}
      summary:SetText(string.format("|cff7fbfffParsing sibling sources…|r  (%d / %d) — watch the loading bar.",
        st.done or 0, st.total or 0))
      if scrollTable then scrollTable:SetData({}) end
      statsText:SetText("Parsing…")
      layout()
      return
    end

    -- Stats reflect the whole window; the table reflects the kind filter.
    local windowFilter = { atTimeFrom = win.from, atTimeTo = win.to }
    local allRecords = UL:Query(windowFilter)
    local stats = foldStats(allRecords)
    renderStats(allRecords, stats)

    -- Table records: window + kind filter (+ optional review-only).
    local tf = { atTimeFrom = win.from, atTimeTo = win.to }
    for _, f in ipairs(FILTERS) do
      if f.key == filterKey then tf.kinds = f.kinds end
    end
    if reviewOnly then tf.review = true end
    local records = UL:Query(tf)

    table.sort(records, function(a, b) return (a.atTime or 0) > (b.atTime or 0) end)
    local capped = #records > MAX_ROWS
    local rows = {}
    for i, rec in ipairs(records) do
      if i > MAX_ROWS then break end
      rows[#rows + 1] = projectRow(rec)
    end
    lastRows = rows
    if scrollTable then scrollTable:SetData(rows) end

    local realmCount = 0
    for _ in pairs(stats.realms) do realmCount = realmCount + 1 end
    local flagged = 0
    for _, r in ipairs(allRecords) do if r.review then flagged = flagged + 1 end end
    summary:SetText(string.format(
      "|cff7fffae%s records|r in window across %d realm%s  •  showing %s%s  •  |cffff6666%s flagged|r",
      formatGroup(#allRecords), realmCount, realmCount == 1 and "" or "s",
      formatGroup(#rows), capped and (" of " .. formatGroup(#records)) or "",
      formatGroup(flagged)))
    layout()
  end

  -- ── Controls ───────────────────────────────────────────────────────────────
  reviewCB:SetScript("OnClick", function(self)
    reviewOnly = self:GetChecked() and true or false
    page:Refresh()
  end)

  exportBtn:SetScript("OnClick", function()
    local lines = {}
    lines[#lines + 1] = "Tally unified ledger — " .. (win.label or "Live")
    lines[#lines + 1] = (summary:GetText() or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    lines[#lines + 1] = ""
    for _, r in ipairs(lastRows) do
      lines[#lines + 1] = string.format("%s | %s | %s | %s | %s | x%s | %s | %s%s",
        r.atTime and date("%m/%d %H:%M", r.atTime) or "?",
        r.char, r.realm, r.kind, r.itemName, tostring(r.qty),
        formatGoldShort(r.copper):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""),
        r.sources, r.flag ~= "" and ("  [" .. r.flag .. "]") or "")
    end
    if ns.Output then
      ns.Output:Inspect(table.concat(lines, "\n"),
        "Tally unified ledger — paste into a GitHub issue or spreadsheet.")
    end
  end)

  -- ── Lifecycle ─────────────────────────────────────────────────────────────
  page:HookScript("OnShow", function()
    if ns.Spine and ns.Spine.ParseCache then ns.Spine.ParseCache:Ensure() end
    page:Refresh()
  end)

  if ns.Spine and ns.Spine.ParseCache and ns.Spine.ParseCache.RegisterListener then
    ns.Spine.ParseCache:RegisterListener("ledger-view", function(st)
      if page:IsShown() and st and (st.phase == "ready" or st.phase == "error") then
        page:Refresh()
      end
    end)
  end

  return page
end
