-- Tally — UI/ResearchPage.lua
--
-- Per-item research view: header (icon + name + link + ID), pricing summary
-- with all-source breakdown, ownership table, price-history + inventory-
-- history sparklines side by side, and (when FlipQueue is installed) sales
-- summary. Driven by ns.Research:GetRecord; mirrors what /tally research
-- prints in chat but with visual sparklines and a permanent input.
--
-- Public surface:
--   page = ns.UI.CreateResearchPage(parent)
--   page:LookUp(input)   — accepts itemlink, item ID, or name; updates UI
--
-- The slash command (/tally research <input>) calls into LookUp.

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

local LOC_ORDER = { "bags", "reagent", "bank", "mail", "equipped", "void", "auctions", "warbank" }

local function formatGold(copper)
  return ns.NetWorth.FormatGold(copper or 0)
end

local function formatGoldShort(copper)
  copper = math.floor(copper or 0)
  local gold = math.floor(copper / 10000)
  if gold >= 1000000 then return string.format("%.1fM|cffffd700g|r", gold / 1000000)
  elseif gold >= 1000 then return string.format("%.1fk|cffffd700g|r", gold / 1000) end
  return formatGold(copper)
end

local function formatLocations(locations)
  if not locations then return "" end
  local parts = {}
  for _, loc in ipairs(LOC_ORDER) do
    local n = locations[loc]
    if n and n > 0 then
      parts[#parts + 1] = loc .. " ×" .. n
    end
  end
  return table.concat(parts, ", ")
end

local function formatTrendDelta(trend, formatter)
  if not trend then return "—", themeColor("textDim", { 0.6, 0.6, 0.6, 1 }) end
  local pct = trend.deltaPct
  local sign = pct >= 0 and "+" or "-"
  local r, g, b
  if math.abs(pct) < 0.5 then
    r, g, b = themeColor("textDim", { 0.6, 0.6, 0.6, 1 })
  elseif pct >= 0 then
    r, g, b = themeColor("success", { 0.30, 0.85, 0.30, 1 })
  else
    r, g, b = themeColor("error", { 1, 0.25, 0.25, 1 })
  end
  return string.format("%s%.1f%%", sign, math.abs(pct)), r, g, b
end

local function formatInvDelta(trend)
  if not trend then return "—", themeColor("textDim", { 0.6, 0.6, 0.6, 1 }) end
  local d = trend.delta
  local sign = d >= 0 and "+" or ""
  local r, g, b
  if d == 0 then
    r, g, b = themeColor("textDim", { 0.6, 0.6, 0.6, 1 })
  elseif d > 0 then
    r, g, b = themeColor("success", { 0.30, 0.85, 0.30, 1 })
  else
    r, g, b = themeColor("error", { 1, 0.25, 0.25, 1 })
  end
  return sign .. d, r, g, b
end

function ns.UI.CreateResearchPage(parent)
  local page = CreateFrame("Frame", nil, parent)

  -- Top: lookup input row -----------------------------------------------------

  local row = CreateFrame("Frame", nil, page)
  row:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
  row:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 0)
  row:SetHeight(26)

  local lookupLabel = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  lookupLabel:SetPoint("LEFT", row, "LEFT", 0, 0)
  lookupLabel:SetText("Item:")

  local input = CreateFrame("EditBox", nil, row, "BackdropTemplate")
  input:SetPoint("LEFT", lookupLabel, "RIGHT", 8, 0)
  input:SetSize(360, 22)
  input:SetAutoFocus(false)
  input:SetFontObject("GameFontHighlight")
  input:SetTextInsets(6, 6, 0, 0)
  input:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  input:SetBackdropColor(themeColor("bgDark", { 0.04, 0.04, 0.07, 1 }))
  input:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))

  local lookupBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  lookupBtn:SetSize(80, 22)
  lookupBtn:SetPoint("LEFT", input, "RIGHT", 6, 0)
  lookupBtn:SetText("Look up")

  -- Item header ---------------------------------------------------------------

  local header = CreateFrame("Frame", nil, page)
  header:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -10)
  header:SetPoint("TOPRIGHT", row, "BOTTOMRIGHT", 0, -10)
  header:SetHeight(60)

  local icon = header:CreateTexture(nil, "ARTWORK")
  icon:SetPoint("LEFT", header, "LEFT", 0, 0)
  icon:SetSize(40, 40)
  icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

  local name = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, -2)
  name:SetText("(no item selected)")

  local sub = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  sub:SetPoint("TOPLEFT", name, "BOTTOMLEFT", 0, -2)
  sub:SetText("Type an item link, ID, or name above.")

  -- Context line: Auctionator shopping-list memberships + active FQ todos.
  -- Hidden when neither has anything to surface.
  local context = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  context:SetPoint("TOPLEFT", sub, "BOTTOMLEFT", 0, -2)
  context:SetPoint("RIGHT", header, "RIGHT", -4, 0)
  context:SetJustifyH("LEFT")
  context:SetTextColor(themeColor("textDim", { 0.6, 0.6, 0.6, 1 }))
  context:Hide()

  -- Stats row -----------------------------------------------------------------

  local stats = CreateFrame("Frame", nil, page)
  stats:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -10)
  stats:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -10)
  stats:SetHeight(40)

  local function makeStat(parent, x)
    local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lbl:SetPoint("TOPLEFT", parent, "TOPLEFT", x, 0)
    lbl:SetTextColor(themeColor("textDim", { 0.6, 0.6, 0.6, 1 }))
    local val = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    val:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -2)
    return lbl, val
  end

  local lblPrice, valPrice = makeStat(stats, 0)
  lblPrice:SetText("UNIT VALUE")
  local lblOwn, valOwn = makeStat(stats, 130)
  lblOwn:SetText("OWNED")
  local lblSale, valSale = makeStat(stats, 230)
  lblSale:SetText("SALEABLE")
  local lblNW, valNW = makeStat(stats, 330)
  lblNW:SetText("NET-WORTH SHARE")
  local lblOW, valOW = makeStat(stats, 470)
  lblOW:SetText("OWNED-WORTH SHARE")

  -- Sparkline strip (price + inventory side by side) --------------------------

  local sparkRow = CreateFrame("Frame", nil, page)
  sparkRow:SetPoint("TOPLEFT", stats, "BOTTOMLEFT", 0, -8)
  sparkRow:SetPoint("TOPRIGHT", stats, "BOTTOMRIGHT", 0, -8)
  sparkRow:SetHeight(80)

  local function makeSparkPanel(parent, anchorPoint, anchorRel, x)
    local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    panel:SetPoint("TOPLEFT", parent, "TOPLEFT", x, 0)
    panel:SetWidth(316) -- two side-by-side fit in ~640px page width
    panel:SetHeight(80)
    panel:SetBackdrop({
      bgFile = "Interface\\Buttons\\WHITE8x8",
      edgeFile = "Interface\\Buttons\\WHITE8x8",
      edgeSize = 1,
    })
    panel:SetBackdropColor(themeColor("bgDark", { 0.04, 0.04, 0.07, 0.6 }))
    panel:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))

    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 6, -4)
    panel.title = title

    local d7 = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d7:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -68, -4)
    d7:SetText("7d —")
    panel.d7 = d7

    local d30 = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d30:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -8, -4)
    d30:SetText("30d —")
    panel.d30 = d30

    local spark = ns.UI.CreateLineChart(panel, { minimal = true, thickness = 1 })
    spark:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 4, 4)
    spark:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -4, 4)
    spark:SetHeight(50)
    panel.spark = spark
    return panel
  end

  local pricePanel = makeSparkPanel(sparkRow, "TOPLEFT", page, 0)
  pricePanel.title:SetText("PRICE HISTORY")
  pricePanel.spark:SetYFormatter(formatGoldShort)

  local invPanel = makeSparkPanel(sparkRow, "TOPLEFT", page, 324)
  invPanel.title:SetText("INVENTORY HISTORY")
  invPanel.spark:SetYFormatter(function(n) return tostring(math.floor(n)) end)

  -- Two scroll panels side by side: ownership on the left, per-realm
  -- P&L breakdown on the right. Each gets ~half the page width, with the
  -- right column slightly wider to accommodate the realm breakdown columns.

  local ownerHdr = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  ownerHdr:SetPoint("TOPLEFT", sparkRow, "BOTTOMLEFT", 0, -10)
  ownerHdr:SetText("WHERE IT LIVES")
  ownerHdr:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local ownerScroll = CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
  ownerScroll:SetPoint("TOPLEFT", ownerHdr, "BOTTOMLEFT", 0, -4)
  ownerScroll:SetWidth(300)
  ownerScroll:SetPoint("BOTTOM", page, "BOTTOM", 0, 56)
  local ownerContent = CreateFrame("Frame", nil, ownerScroll)
  ownerContent:SetSize(280, 1)
  ownerScroll:SetScrollChild(ownerContent)

  local realmHdr = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  realmHdr:SetPoint("TOPLEFT", ownerScroll, "TOPRIGHT", 24, 14)
  realmHdr:SetText("PER REALM (P&L)")
  realmHdr:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local realmScroll = CreateFrame("ScrollFrame", nil, page, "UIPanelScrollFrameTemplate")
  realmScroll:SetPoint("TOPLEFT", realmHdr, "BOTTOMLEFT", 0, -4)
  realmScroll:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -22, 56)
  local realmContent = CreateFrame("Frame", nil, realmScroll)
  realmContent:SetSize(320, 1)
  realmScroll:SetScrollChild(realmContent)

  -- Column headers for the realm table (rendered as a fixed first row).
  local realmHeaderRow = CreateFrame("Frame", nil, realmContent)
  realmHeaderRow:SetPoint("TOPLEFT", realmContent, "TOPLEFT", 0, 0)
  realmHeaderRow:SetPoint("RIGHT", realmContent, "RIGHT", 0, 0)
  realmHeaderRow:SetHeight(14)
  local function makeRealmHdrCol(parent, x, w, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    fs:SetPoint("LEFT", parent, "LEFT", x, 0)
    fs:SetWidth(w); fs:SetJustifyH(x == 0 and "LEFT" or "RIGHT")
    fs:SetText(text)
    fs:SetTextColor(themeColor("textDim", { 0.6, 0.6, 0.6, 1 }))
  end
  --   Realm 0..120 | Sold 120..150 | Bought 150..180 | Net 180..end
  makeRealmHdrCol(realmHeaderRow, 0,   120, "REALM")
  makeRealmHdrCol(realmHeaderRow, 120, 50,  "SOLD")
  makeRealmHdrCol(realmHeaderRow, 170, 60,  "BOUGHT")
  local netHdr = realmHeaderRow:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  netHdr:SetPoint("RIGHT", realmHeaderRow, "RIGHT", -2, 0)
  netHdr:SetText("NET")
  netHdr:SetTextColor(themeColor("textDim", { 0.6, 0.6, 0.6, 1 }))

  local realmRows = {}
  local function getRealmRow(i)
    local r = realmRows[i]
    if not r then
      r = CreateFrame("Frame", nil, realmContent)
      r:SetHeight(16)
      r:SetPoint("LEFT", realmContent, "LEFT", 0, 0)
      r:SetPoint("RIGHT", realmContent, "RIGHT", 0, 0)
      r.realm = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      r.realm:SetPoint("LEFT", r, "LEFT", 0, 0)
      r.realm:SetWidth(120); r.realm:SetJustifyH("LEFT")
      r.sold = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      r.sold:SetPoint("LEFT", r, "LEFT", 120, 0)
      r.sold:SetWidth(50); r.sold:SetJustifyH("RIGHT")
      r.bought = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      r.bought:SetPoint("LEFT", r, "LEFT", 170, 0)
      r.bought:SetWidth(60); r.bought:SetJustifyH("RIGHT")
      r.net = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      r.net:SetPoint("RIGHT", r, "RIGHT", -2, 0)
      r.net:SetJustifyH("RIGHT")
      realmRows[i] = r
    end
    return r
  end

  local ownerRows = {}
  local function getOwnerRow(i)
    local row = ownerRows[i]
    if not row then
      row = CreateFrame("Frame", nil, ownerContent)
      row:SetHeight(18)
      row:SetPoint("LEFT", ownerContent, "LEFT", 0, 0)
      row:SetPoint("RIGHT", ownerContent, "RIGHT", 0, 0)
      row.charKey = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.charKey:SetPoint("LEFT", row, "LEFT", 0, 0)
      row.charKey:SetWidth(180)
      row.charKey:SetJustifyH("LEFT")
      row.qty = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      row.qty:SetPoint("LEFT", row.charKey, "RIGHT", 0, 0)
      row.qty:SetWidth(80)
      row.qty:SetJustifyH("RIGHT")
      row.locs = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
      row.locs:SetPoint("LEFT", row.qty, "RIGHT", 12, 0)
      row.locs:SetPoint("RIGHT", row, "RIGHT", -4, 0)
      row.locs:SetJustifyH("LEFT")
      ownerRows[i] = row
    end
    return row
  end

  -- Sales + P&L footer --------------------------------------------------------

  local sales = CreateFrame("Frame", nil, page)
  sales:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 0, 0)
  sales:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
  sales:SetHeight(48)

  -- Left column: sales activity summary.
  local salesLbl = sales:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  salesLbl:SetPoint("TOPLEFT", sales, "TOPLEFT", 0, 0)
  salesLbl:SetTextColor(themeColor("textDim", { 0.6, 0.6, 0.6, 1 }))

  local salesVal = sales:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  salesVal:SetPoint("TOPLEFT", salesLbl, "BOTTOMLEFT", 0, -2)
  salesVal:SetWidth(320); salesVal:SetJustifyH("LEFT")

  -- Right column: profit-and-loss summary.
  local pnlLbl = sales:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  pnlLbl:SetPoint("TOPLEFT", sales, "TOPLEFT", 340, 0)
  pnlLbl:SetTextColor(themeColor("textDim", { 0.6, 0.6, 0.6, 1 }))

  local pnlVal = sales:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  pnlVal:SetPoint("TOPLEFT", pnlLbl, "BOTTOMLEFT", 0, -2)
  pnlVal:SetPoint("RIGHT", sales, "RIGHT", 0, 0)
  pnlVal:SetJustifyH("LEFT")

  -- Refresh logic -------------------------------------------------------------

  local currentRecord = nil

  local function clearOwnerRows(usedCount)
    for i = usedCount + 1, #ownerRows do
      ownerRows[i]:Hide()
    end
  end

  local function applyRecord(record)
    currentRecord = record
    if not record then
      icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
      name:SetText("(no item selected)")
      sub:SetText("Type an item link, ID, or name above.")
      context:Hide()
      valPrice:SetText("—")
      valOwn:SetText("—")
      valSale:SetText("—")
      valNW:SetText("—")
      valOW:SetText("—")
      pricePanel.spark:SetData({})
      pricePanel.d7:SetText("7d —")
      pricePanel.d30:SetText("30d —")
      invPanel.spark:SetData({})
      invPanel.d7:SetText("7d —")
      invPanel.d30:SetText("30d —")
      clearOwnerRows(0)
      for i = 1, #realmRows do realmRows[i]:Hide() end
      salesLbl:SetText("")
      salesVal:SetText("")
      pnlLbl:SetText("")
      pnlVal:SetText("")
      return
    end

    -- Header
    icon:SetTexture(record.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    local displayName = record.itemLink or record.name or ("item:" .. (record.itemID or "?"))
    name:SetText(displayName)
    local subParts = {}
    if record.itemID then subParts[#subParts + 1] = "id:" .. record.itemID end
    if record.isPet then subParts[#subParts + 1] = "battle pet" end
    if record.pricing and record.pricing.strategy then
      subParts[#subParts + 1] = "strategy: " .. record.pricing.strategy
    end
    if record.tsmGroup and record.tsmGroup ~= "" then
      subParts[#subParts + 1] = "TSM group: " .. record.tsmGroup
    end
    sub:SetText(table.concat(subParts, "  •  "))

    -- Context line: Auctionator shopping list memberships + FQ todos.
    local ctxParts = {}
    if record.auctionatorLists and #record.auctionatorLists > 0 then
      ctxParts[#ctxParts + 1] = "Auctionator: " .. table.concat(record.auctionatorLists, ", ")
    end
    if record.fqTodos and #record.fqTodos > 0 then
      local byAction = {}
      for _, t in ipairs(record.fqTodos) do
        local key = t.action or "task"
        byAction[key] = (byAction[key] or 0) + 1
      end
      local todoParts = {}
      for action, count in pairs(byAction) do
        todoParts[#todoParts + 1] = string.format("%d %s", count, action)
      end
      table.sort(todoParts)
      ctxParts[#ctxParts + 1] = "FQ todos: " .. table.concat(todoParts, ", ")
    end
    if record.activeAuctions and #record.activeAuctions > 0 then
      local total = 0
      for _, a in ipairs(record.activeAuctions) do total = total + (a.quantity or 1) end
      ctxParts[#ctxParts + 1] = string.format("Active auctions: %d (×%d total)",
        #record.activeAuctions, total)
    end
    if #ctxParts > 0 then
      context:SetText(table.concat(ctxParts, "  •  "))
      context:Show()
    else
      context:Hide()
    end

    -- Stats
    if record.pricing and record.pricing.unitValue and record.pricing.unitValue > 0 then
      valPrice:SetText(formatGold(record.pricing.unitValue))
    else
      valPrice:SetText("—")
    end
    valOwn:SetText(tostring(record.totalInventory or 0))
    valSale:SetText(tostring(record.saleableInventory or 0))
    valNW:SetText(formatGoldShort(record.valuation and record.valuation.netWorthContribution or 0))
    valOW:SetText(formatGoldShort(record.valuation and record.valuation.ownedWorthContribution or 0))

    -- Price sparkline
    if record.history and record.history.points and #record.history.points >= 2 then
      local pts = {}
      for _, p in ipairs(record.history.points) do
        pts[#pts + 1] = { x = p.atTime, y = p.copper }
      end
      pricePanel.spark:SetData(pts)
      local s7, r7, g7, b7 = formatTrendDelta(record.history.trend7d)
      local s30, r30, g30, b30 = formatTrendDelta(record.history.trend30d)
      pricePanel.d7:SetText("7d " .. s7)
      pricePanel.d7:SetTextColor(r7, g7, b7)
      pricePanel.d30:SetText("30d " .. s30)
      pricePanel.d30:SetTextColor(r30, g30, b30)
    else
      pricePanel.spark:SetData({})
      pricePanel.d7:SetText("7d —")
      pricePanel.d7:SetTextColor(themeColor("textDim", { 0.6, 0.6, 0.6, 1 }))
      pricePanel.d30:SetText("30d —")
      pricePanel.d30:SetTextColor(themeColor("textDim", { 0.6, 0.6, 0.6, 1 }))
    end

    -- Inventory sparkline
    if record.inventoryHistory and record.inventoryHistory.points
       and #record.inventoryHistory.points >= 2 then
      local pts = {}
      for _, p in ipairs(record.inventoryHistory.points) do
        pts[#pts + 1] = { x = p.atTime, y = p.total }
      end
      invPanel.spark:SetData(pts)
      local s7, r7, g7, b7 = formatInvDelta(record.inventoryHistory.trend7d)
      local s30, r30, g30, b30 = formatInvDelta(record.inventoryHistory.trend30d)
      invPanel.d7:SetText("7d " .. s7)
      invPanel.d7:SetTextColor(r7, g7, b7)
      invPanel.d30:SetText("30d " .. s30)
      invPanel.d30:SetTextColor(r30, g30, b30)
    else
      invPanel.spark:SetData({})
      invPanel.d7:SetText("7d —")
      invPanel.d7:SetTextColor(themeColor("textDim", { 0.6, 0.6, 0.6, 1 }))
      invPanel.d30:SetText("30d —")
      invPanel.d30:SetTextColor(themeColor("textDim", { 0.6, 0.6, 0.6, 1 }))
    end

    -- Ownership table
    local rows = {}
    for _, inv in ipairs(record.inventory or {}) do
      rows[#rows + 1] = inv
    end
    table.sort(rows, function(a, b) return (a.quantity or 0) > (b.quantity or 0) end)

    for i, inv in ipairs(rows) do
      local r = getOwnerRow(i)
      r:SetPoint("TOPLEFT", ownerContent, "TOPLEFT", 0, -(i - 1) * 18)
      r.charKey:SetText(inv.charKey)
      local qtyText
      if inv.saleable and inv.saleable < inv.quantity then
        qtyText = string.format("×%d (%d saleable)", inv.quantity, inv.saleable)
      else
        qtyText = "×" .. inv.quantity
      end
      r.qty:SetText(qtyText)
      r.locs:SetText(formatLocations(inv.locations))
      r:Show()
    end
    clearOwnerRows(#rows)
    ownerContent:SetHeight(math.max(1, #rows * 18))

    -- Per-realm P&L table.
    local realmList = {}
    if record.profitByRealm then
      for realm, data in pairs(record.profitByRealm) do
        realmList[#realmList + 1] = { realm = realm, data = data }
      end
    end
    table.sort(realmList, function(a, b) return math.abs(a.data.netProfit) > math.abs(b.data.netProfit) end)

    local sR, sG, sB = themeColor("success", { 0.30, 0.85, 0.30, 1 })
    local eR, eG, eB = themeColor("error",   { 1.00, 0.40, 0.40, 1 })
    local nR, nG, nB = themeColor("textDim", { 0.6,  0.6,  0.6,  1 })

    for i, item in ipairs(realmList) do
      local row = getRealmRow(i)
      row:SetPoint("TOPLEFT", realmContent, "TOPLEFT", 0, -14 - (i - 1) * 16)
      row.realm:SetText(item.realm)
      row.sold:SetText(item.data.salesCount > 0 and tostring(item.data.salesCount) or "")
      row.bought:SetText(item.data.purchaseCount > 0 and tostring(item.data.purchaseCount) or "")
      local n = item.data.netProfit
      local sign = n >= 0 and "+" or "-"
      row.net:SetText(sign .. formatGoldShort(math.abs(n)))
      if n > 0 then row.net:SetTextColor(sR, sG, sB)
      elseif n < 0 then row.net:SetTextColor(eR, eG, eB)
      else row.net:SetTextColor(nR, nG, nB) end
      row:Show()
    end
    for i = #realmList + 1, #realmRows do realmRows[i]:Hide() end
    realmContent:SetHeight(math.max(1, 14 + #realmList * 16))

    -- Sales
    if record.salesSummary and record.salesSummary.count and record.salesSummary.count > 0 then
      local parts = { string.format("%d sold • %s revenue • avg %s",
        record.salesSummary.count,
        formatGold(record.salesSummary.totalRevenue),
        formatGold(record.salesSummary.avgPrice)) }
      if record.purchasesSummary and record.purchasesSummary.count > 0 then
        parts[#parts + 1] = string.format("%d bought • %s spent",
          record.purchasesSummary.count,
          formatGold(record.purchasesSummary.totalCost))
      end
      salesLbl:SetText("ACTIVITY")
      salesVal:SetText(table.concat(parts, "  •  "))
    elseif record.purchasesSummary and record.purchasesSummary.count > 0 then
      salesLbl:SetText("PURCHASES")
      salesVal:SetText(string.format("%d bought • %s spent",
        record.purchasesSummary.count,
        formatGold(record.purchasesSummary.totalCost)))
    elseif record.activeAuctions and #record.activeAuctions > 0 then
      salesLbl:SetText("ACTIVE AUCTIONS")
      salesVal:SetText(tostring(#record.activeAuctions))
    else
      salesLbl:SetText("")
      salesVal:SetText("")
    end

    -- P&L (right column).
    if record.profitSummary and (record.profitSummary.salesCount > 0
       or record.profitSummary.purchaseCount > 0) then
      pnlLbl:SetText("P&L")
      local p = record.profitSummary
      local sign = p.netProfit >= 0 and "+" or "-"
      local r, g, b
      if p.netProfit >= 0 then
        r, g, b = themeColor("success", { 0.30, 0.85, 0.30, 1 })
      else
        r, g, b = themeColor("error", { 1.00, 0.40, 0.40, 1 })
      end
      local perUnitTxt = ""
      if p.salesQty > 0 then
        local pSign = p.perUnitProfit >= 0 and "+" or "-"
        perUnitTxt = string.format("  •  per-unit %s%s", pSign, formatGold(math.abs(p.perUnitProfit)))
      end
      local feesTxt = ""
      if p.totalFees > 0 then
        feesTxt = string.format("  •  fees %s", formatGold(p.totalFees))
      end
      pnlVal:SetText(string.format("Net %s%s%s%s",
        sign, formatGold(math.abs(p.netProfit)), perUnitTxt, feesTxt))
      pnlVal:SetTextColor(r, g, b)
    else
      pnlLbl:SetText("")
      pnlVal:SetText("")
    end
  end

  function page:LookUp(text)
    if not text or text == "" then return end
    input:SetText(text)
    input:ClearFocus()
    if not (ns.Research and ns.Research.GetRecord) then return end
    local record = ns.Research:GetRecord(text)
    applyRecord(record)
  end

  function page:Refresh()
    -- Re-fetch the current item if there is one — picks up new history
    -- snapshots without requiring the user to re-look up.
    if currentRecord and currentRecord.itemKey then
      local fresh = ns.Research:GetRecord(currentRecord.itemKey)
      applyRecord(fresh)
    end
  end

  -- Wire input + button.
  local function trigger()
    local text = input:GetText()
    if text and text ~= "" then page:LookUp(text) end
  end
  input:SetScript("OnEnterPressed", trigger)
  input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  lookupBtn:SetScript("OnClick", trigger)

  applyRecord(nil)
  return page
end

-- Convenience: open MainFrame on the Research page and run a lookup.
function ns.UI.ShowResearch(input)
  if not ns.UI.MainFrame then return end
  ns.UI.MainFrame:Show()
  ns.UI.MainFrame:ShowPage("Research")
  local page = ns.UI.MainFrame:GetPage("Research")
  if page and input and input ~= "" then page:LookUp(input) end
end
