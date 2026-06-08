-- Tally — UI/SummaryView.lua
--
-- Summary view (TLY-85) — the headline view under Live / Historical.
--
-- Window-aware (the nav shell calls :SetWindow(from, to, label)):
--   * Net-worth graph over the active window, with a Net/Owned basis toggle
--     and a Total/Gold/Items series toggle ("configurable sparklines").
--   * Key summary metrics: net worth now, change over the window, realized
--     P&L, operating cost, and transaction count.
--   * Operating-cost-over-time: window total + per-category breakdown.
--   * Best / worst performing products over the window (by realized P&L).
--
-- Data sources:
--   * Net-worth series + "now"  — Spine/NetWorthStore (persisted; no parse).
--   * P&L / cost / products     — Spine/Aggregates (recompute-on-parse), so
--                                 those panes show a "parsing…" state until
--                                 the session parse settles.
--   * Transaction count         — Spine/UnifiedLedger:Stats (windowed).

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

local function itemName(itemID)
  if not itemID then return "(no item)" end
  local name = GetItemInfo and GetItemInfo(itemID)
  return name or ("item:" .. tostring(itemID))
end

-- Period keys ("YYYY-MM") whose month overlaps [from, to]. Month-granularity
-- matches the Aggregates store; `from` 0 means "all", `to` nil means "now".
local function periodsInWindow(from, to)
  local Agg = ns.Spine and ns.Spine.Aggregates
  if not (Agg and Agg.GetPeriods) then return {} end
  local fromKey = (from and from > 0) and date("%Y-%m", from) or "0000-00"
  local toKey   = date("%Y-%m", to or time())
  local out = {}
  for _, pk in ipairs(Agg:GetPeriods()) do
    if pk >= fromKey and pk <= toKey then out[#out + 1] = pk end
  end
  return out
end

-- Fold the Aggregates periods in a window into one rollup:
--   { realized, cost = {ahCut,deposits,repairs,other,total},
--     items = { [itemID] = realized } }
local function windowRollup(from, to)
  local Agg = ns.Spine and ns.Spine.Aggregates
  local roll = {
    realized = 0,
    cost = { ahCut = 0, deposits = 0, repairs = 0, other = 0, total = 0 },
    items = {},
    periods = 0,
    partial = false,
  }
  if not (Agg and Agg.Get) then return roll end
  for _, pk in ipairs(periodsInWindow(from, to)) do
    local p = Agg:Get(pk)
    if p then
      roll.periods = roll.periods + 1
      if p.meta and p.meta.partial then roll.partial = true end
      for k in pairs(roll.cost) do
        if k ~= "total" then
          roll.cost[k] = roll.cost[k] + ((p.costs and p.costs[k]) or 0)
        end
      end
      for itemID, it in pairs(p.items or {}) do
        local r = it.realized or ((it.sold or 0) - (it.bought or 0))
        roll.realized = roll.realized + r
        roll.items[itemID] = (roll.items[itemID] or 0) + r
      end
    end
  end
  roll.cost.total = roll.cost.ahCut + roll.cost.deposits + roll.cost.repairs + roll.cost.other
  return roll
end

-- Top-N best and worst products by realized P&L from a window rollup.
local function bestWorst(roll, n)
  local list = {}
  for itemID, realized in pairs(roll.items) do
    list[#list + 1] = { itemID = itemID, realized = realized }
  end
  table.sort(list, function(a, b) return a.realized > b.realized end)
  local best, worst = {}, {}
  for i = 1, math.min(n, #list) do best[i] = list[i] end
  for i = 0, math.min(n, #list) - 1 do worst[i + 1] = list[#list - i] end
  return best, worst
end

function ns.UI.CreateSummaryView(parent)
  local page = CreateFrame("Frame", nil, parent)
  local win = { from = 0, to = nil, label = "Live" }
  local basis = "net"      -- "net" | "owned"
  local series = "total"   -- "total" | "gold" | "items"

  -- ── Header: window label + toggles ──────────────────────────────────────
  local header = CreateFrame("Frame", nil, page)
  header:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
  header:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 0)
  header:SetHeight(24)

  local winLabel = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  winLabel:SetPoint("LEFT", header, "LEFT", 2, 0)
  winLabel:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  -- Small toggle-button helper (returns the button; caller wires OnClick).
  local function toggleBtn(text, anchor, xoff)
    local b = CreateFrame("Button", nil, header, "UIPanelButtonTemplate")
    b:SetSize(58, 20)
    if anchor == header then b:SetPoint("RIGHT", header, "RIGHT", xoff, 0)
    else b:SetPoint("RIGHT", anchor, "LEFT", xoff, 0) end
    b:SetText(text)
    return b
  end

  local itemsBtn = toggleBtn("Items", header, 0)
  local goldBtn  = toggleBtn("Gold", itemsBtn, -2)
  local totalBtn = toggleBtn("Total", goldBtn, -2)
  local ownedBtn = toggleBtn("Owned", totalBtn, -10)
  local netBtn   = toggleBtn("Net", ownedBtn, -2)

  -- ── Chart ───────────────────────────────────────────────────────────────
  local chart = ns.UI.CreateLineChart(page, { height = 150 })
  chart:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
  chart:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -6)
  chart:SetHeight(150)
  chart:SetXFormatter(function(x) return date("%m/%d", x) end)
  chart:SetYFormatter(function(y) return formatGoldShort(y) end)

  local chartEmpty = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  chartEmpty:SetPoint("CENTER", chart, "CENTER", 0, 0)
  chartEmpty:SetText("No net-worth snapshots in this window yet — they accrue once per day.")
  chartEmpty:Hide()

  -- ── Metrics row ─────────────────────────────────────────────────────────
  local metrics = CreateFrame("Frame", nil, page)
  metrics:SetPoint("TOPLEFT", chart, "BOTTOMLEFT", 0, -10)
  metrics:SetPoint("TOPRIGHT", chart, "BOTTOMRIGHT", 0, -10)
  metrics:SetHeight(46)

  local METRIC_KEYS = { "now", "delta", "realized", "cost", "txns" }
  local METRIC_LABELS = {
    now = "Net worth", delta = "Change", realized = "Realized P&L",
    cost = "Operating cost", txns = "Transactions",
  }
  local metricCards = {}
  do
    for _, key in ipairs(METRIC_KEYS) do
      -- Position + size is assigned by layoutMetrics() (the row width is
      -- dynamic); here we just create the card and its labels.
      local card = CreateFrame("Frame", nil, metrics, "BackdropTemplate")
      card:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
      })
      card:SetBackdropColor(themeColor("bgDark", { 0.04, 0.04, 0.07, 0.7 }))
      card:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))
      local lbl = card:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      lbl:SetPoint("TOPLEFT", card, "TOPLEFT", 6, -4)
      lbl:SetText(METRIC_LABELS[key])
      local val = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
      val:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 6, 6)
      val:SetText("—")
      metricCards[key] = { card = card, val = val }
    end
  end

  -- Lay the metric cards out evenly across the row width. Done on every
  -- refresh/resize since the frame width is dynamic.
  local function layoutMetrics()
    local w = metrics:GetWidth()
    if w <= 0 then return end
    local n = #METRIC_KEYS
    local gap = 6
    local cw = (w - gap * (n - 1)) / n
    for i, key in ipairs(METRIC_KEYS) do
      local card = metricCards[key].card
      card:ClearAllPoints()
      card:SetPoint("TOPLEFT", metrics, "TOPLEFT", (i - 1) * (cw + gap), 0)
      card:SetSize(cw, metrics:GetHeight())
    end
  end
  metrics:SetScript("OnSizeChanged", layoutMetrics)

  -- ── Bottom split: operating cost (left) + best/worst (right) ─────────────
  local bottom = CreateFrame("Frame", nil, page)
  bottom:SetPoint("TOPLEFT", metrics, "BOTTOMLEFT", 0, -10)
  bottom:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)

  local function panel(title)
    local f = CreateFrame("Frame", nil, bottom, "BackdropTemplate")
    f:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1,
    })
    f:SetBackdropColor(themeColor("bgDark", { 0.04, 0.04, 0.07, 0.5 }))
    f:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))
    local hdr = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    hdr:SetPoint("TOPLEFT", f, "TOPLEFT", 8, -6)
    hdr:SetText(title)
    hdr:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))
    local body = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    body:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, -6)
    body:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -8, 8)
    body:SetJustifyH("LEFT")
    body:SetJustifyV("TOP")
    body:SetSpacing(3)
    return f, body
  end

  local costPanel, costBody = panel("Operating cost")
  costPanel:SetPoint("TOPLEFT", bottom, "TOPLEFT", 0, 0)
  costPanel:SetPoint("BOTTOMRIGHT", bottom, "BOTTOM", -4, 0)

  local prodPanel, prodBody = panel("Best / worst products")
  prodPanel:SetPoint("TOPLEFT", bottom, "TOP", 4, 0)
  prodPanel:SetPoint("BOTTOMRIGHT", bottom, "BOTTOMRIGHT", 0, 0)

  -- ── Toggle wiring ────────────────────────────────────────────────────────
  local function restyleToggles()
    local function set(b, on)
      if on then b:SetNormalFontObject("GameFontNormalSmall")
      else b:SetNormalFontObject("GameFontDisableSmall") end
    end
    set(netBtn,   basis == "net")
    set(ownedBtn, basis == "owned")
    set(totalBtn, series == "total")
    set(goldBtn,  series == "gold")
    set(itemsBtn, series == "items")
  end

  -- ── Refresh ───────────────────────────────────────────────────────────────
  function page:SetWindow(from, to, label)
    win.from, win.to, win.label = from or 0, to, label or "Live"
  end

  function page:Refresh()
    winLabel:SetText("Summary — " .. (win.label or "Live"))
    restyleToggles()

    -- Net-worth series for the window (persisted snapshots; no parse).
    -- One fetch drives both the chart and the metric cards so basis stays
    -- consistent. Series points already carry the basis-adjusted total.
    local NWS = ns.Spine and ns.Spine.NetWorthStore
    local ser = {}
    if NWS and NWS.GetSeries then
      local fromT = (win.from and win.from > 0) and win.from or 0
      ser = NWS:GetSeries(fromT, win.to or time(), { includeBound = basis == "owned" })
    end

    local pts = {}
    for _, s in ipairs(ser) do
      pts[#pts + 1] = { x = s.atTime, y = s[series] or s.total or 0 }
    end
    if #pts >= 2 then
      chart:Show(); chartEmpty:Hide()
      chart:SetData(pts)
    else
      chart:SetData({})
      chart:Hide(); chartEmpty:Show()
    end

    -- "Net worth now": latest snapshot overall (basis-adjusted), falling
    -- back to a live valuation if no snapshot exists yet.
    local nowTotal
    if NWS and NWS.GetLatest then
      local latest = NWS:GetLatest()
      if latest then nowTotal = (basis == "owned") and latest.ownedTotal or latest.total end
    end
    if not nowTotal and ns.NetWorth then
      local snap = ns.NetWorth:Snapshot({ includeBound = basis == "owned" })
      nowTotal = snap and snap.total
    end
    metricCards.now.val:SetText(nowTotal and formatGold(nowTotal) or "—")

    -- Change over the window: now − the first in-window snapshot's total.
    local deltaStr = "—"
    if nowTotal and ser[1] then
      local delta = nowTotal - (ser[1].total or 0)
      local color = delta >= 0 and "|cff66dd66" or "|cffdd6666"
      deltaStr = color .. (delta >= 0 and "+" or "") .. formatGold(delta) .. "|r"
    end
    metricCards.delta.val:SetText(deltaStr)

    -- P&L / cost / products from the spine aggregates (parse-gated).
    local UL = ns.Spine and ns.Spine.UnifiedLedger
    local ready = UL and UL.IsReady and UL:IsReady()
    if not ready then
      local parsing = "|cff7fbfffparsing…|r"
      metricCards.realized.val:SetText(parsing)
      metricCards.cost.val:SetText(parsing)
      metricCards.txns.val:SetText(parsing)
      costBody:SetText("Parsing sibling sources… open stays responsive; this fills in when the parse settles.")
      prodBody:SetText("Parsing sibling sources…")
      layoutMetrics()
      return
    end

    local roll = windowRollup(win.from, win.to)
    local realizedColor = roll.realized >= 0 and "|cff66dd66" or "|cffdd6666"
    metricCards.realized.val:SetText(realizedColor ..
      (roll.realized >= 0 and "+" or "") .. formatGold(roll.realized) .. "|r")
    metricCards.cost.val:SetText(formatGold(roll.cost.total))

    local stats = UL:Stats({ atTimeFrom = win.from, atTimeTo = win.to })
    metricCards.txns.val:SetText(BreakUpLargeNumbers
      and BreakUpLargeNumbers(stats.count) or tostring(stats.count))

    -- Operating-cost breakdown.
    costBody:SetText(string.format(
      "Total: %s%s\n\nAH cut:    %s\nDeposits:  %s\nRepairs:   %s\nOther:     %s\n\n|cff888888across %d month%s%s|r",
      formatGold(roll.cost.total), roll.partial and "  |cff888888(current month partial)|r" or "",
      formatGold(roll.cost.ahCut), formatGold(roll.cost.deposits),
      formatGold(roll.cost.repairs), formatGold(roll.cost.other),
      roll.periods, roll.periods == 1 and "" or "s",
      roll.partial and ", current partial" or ""))

    -- Best / worst products.
    local best, worst = bestWorst(roll, 5)
    local lines = {}
    lines[#lines + 1] = "|cff66dd66Best|r"
    if #best == 0 then lines[#lines + 1] = "  (no sales in window)" end
    for _, e in ipairs(best) do
      lines[#lines + 1] = string.format("  %s  |cff66dd66%s|r", itemName(e.itemID), formatGoldShort(e.realized))
    end
    lines[#lines + 1] = " "
    lines[#lines + 1] = "|cffdd6666Worst|r"
    local anyWorst = false
    for _, e in ipairs(worst) do
      if e.realized < 0 then
        anyWorst = true
        lines[#lines + 1] = string.format("  %s  |cffdd6666%s|r", itemName(e.itemID), formatGoldShort(e.realized))
      end
    end
    if not anyWorst then lines[#lines + 1] = "  (no losses in window)" end
    prodBody:SetText(table.concat(lines, "\n"))

    layoutMetrics()
  end

  netBtn:SetScript("OnClick",   function() basis = "net";   page:Refresh() end)
  ownedBtn:SetScript("OnClick", function() basis = "owned"; page:Refresh() end)
  totalBtn:SetScript("OnClick", function() series = "total"; page:Refresh() end)
  goldBtn:SetScript("OnClick",  function() series = "gold";  page:Refresh() end)
  itemsBtn:SetScript("OnClick", function() series = "items"; page:Refresh() end)

  -- Opening the view is a lazy-parse trigger (cost/products need the spine).
  page:HookScript("OnShow", function()
    if ns.Spine and ns.Spine.ParseCache then ns.Spine.ParseCache:Ensure() end
    page:Refresh()
  end)

  if ns.Spine and ns.Spine.ParseCache and ns.Spine.ParseCache.RegisterListener then
    ns.Spine.ParseCache:RegisterListener("summary-view", function(st)
      if page:IsShown() and st and (st.phase == "ready" or st.phase == "error") then
        page:Refresh()
      end
    end)
  end

  return page
end
