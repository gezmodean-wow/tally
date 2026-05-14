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

  -- Drill-down to per-item lifecycle (TLY-26): jump to the Lifecycle tab
  -- with the current item pre-loaded. Hidden until a lookup has resolved.
  local lifecycleBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  lifecycleBtn:SetSize(140, 22)
  lifecycleBtn:SetPoint("LEFT", lookupBtn, "RIGHT", 6, 0)
  lifecycleBtn:SetText("View lifecycle →")
  lifecycleBtn:Disable()
  lifecycleBtn:SetScript("OnClick", function()
    local text = input:GetText()
    if text and text ~= "" and ns.UI.ShowLifecycle then
      ns.UI.ShowLifecycle(text)
    end
  end)

  -- TLY-71 Flow B: synthesise missing historical archives from siblings.
  -- The button is identical across Research / Lifecycle / Compare —
  -- synthesis is a global archive operation, not a per-page concept.
  if ns.UI.CreateSynthButton then
    local synthBtn = ns.UI.CreateSynthButton(row)
    synthBtn:SetPoint("LEFT", lifecycleBtn, "RIGHT", 6, 0)
  end

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

  -- Two scroll tables side by side: ownership on the left, per-realm
  -- P&L breakdown on the right. Both powered by Cogworks' CreateScrollTable
  -- so columns are sortable + drag-resizable.

  local cw = getCogworks()
  local hasScrollTable = cw and cw.CreateScrollTable

  local ownerHdr = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  ownerHdr:SetPoint("TOPLEFT", sparkRow, "BOTTOMLEFT", 0, -10)
  ownerHdr:SetText("WHERE IT LIVES")
  ownerHdr:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local ownerHost = CreateFrame("Frame", nil, page)
  ownerHost:SetPoint("TOPLEFT", ownerHdr, "BOTTOMLEFT", 0, -4)
  ownerHost:SetWidth(300)
  ownerHost:SetPoint("BOTTOM", page, "BOTTOM", 0, 56)

  local realmHdr = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  realmHdr:SetPoint("TOPLEFT", ownerHost, "TOPRIGHT", 24, 14)
  realmHdr:SetText("PER REALM (P&L)")
  realmHdr:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local realmHost = CreateFrame("Frame", nil, page)
  realmHost:SetPoint("TOPLEFT", realmHdr, "BOTTOMLEFT", 0, -4)
  realmHost:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 56)

  -- Per-realm net-profit cell: signed gold with color based on sign.
  local function formatRealmNet(v)
    if not v or v == 0 then
      return "|cff999999—|r"
    elseif v > 0 then
      return "|cff4cd64c+" .. formatGoldShort(v) .. "|r"
    else
      return "|cffff6666-" .. formatGoldShort(-v) .. "|r"
    end
  end

  -- Ownership-row quantity cell: total with parenthesized saleable when
  -- they differ. The displayed `qty` value is the numeric total and drives
  -- the sort directly; the formatter only adds the saleable suffix.
  local function formatOwnerQty(_, rowData)
    if not rowData then return "" end
    local total, saleable = rowData._totalCount or 0, rowData._saleableCount or 0
    if saleable < total then
      return string.format("×%d (%d saleable)", total, saleable)
    end
    return "×" .. total
  end

  local ownerTable, realmTable
  if hasScrollTable then
    ownerTable = cw:CreateScrollTable(ownerHost, {
      { key = "charKey", label = "CHARACTER", width = 140, sortable = true },
      { key = "qty",     label = "QTY",       width = 80,  sortable = true,
        align = "RIGHT", format = formatOwnerQty },
      { key = "locs",    label = "LOCATIONS", width = 80,  sortable = true },
    })
    ownerTable:SetSort("qty", false)

    realmTable = cw:CreateScrollTable(realmHost, {
      { key = "realm",  label = "REALM",  width = 120, sortable = true },
      { key = "sold",   label = "SOLD",   width = 50,  sortable = true, align = "RIGHT" },
      { key = "bought", label = "BOUGHT", width = 60,  sortable = true, align = "RIGHT" },
      { key = "net",    label = "NET",    width = 80,  sortable = true,
        align = "RIGHT", format = formatRealmNet },
    })
    realmTable:SetSort("net", false)
  else
    -- Cogworks ScrollTable unavailable — render a stub message under each header.
    local function stub(host)
      local fs = host:CreateFontString(nil, "OVERLAY", "GameFontDisable")
      fs:SetPoint("CENTER")
      fs:SetText("(requires Cogworks-1.0 ScrollTable)")
    end
    stub(ownerHost); stub(realmHost)
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
      if ownerTable then ownerTable:SetData({}) end
      if realmTable then realmTable:SetData({}) end
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

    -- Ownership table — feed into Cogworks ScrollTable. `qty` is the numeric
    -- total (drives sort); the formatter uses _totalCount / _saleableCount
    -- for the "(N saleable)" suffix when those differ.
    if ownerTable then
      local ownerRowsData = {}
      for _, inv in ipairs(record.inventory or {}) do
        local total = inv.quantity or 0
        local saleable = inv.saleable or total
        ownerRowsData[#ownerRowsData + 1] = {
          charKey         = inv.charKey,
          qty             = total,
          locs            = formatLocations(inv.locations),
          _totalCount     = total,
          _saleableCount  = saleable,
        }
      end
      ownerTable:SetData(ownerRowsData)
    end

    -- Per-realm P&L table. `net` is signed copper, sort numeric. Default
    -- descending = biggest profit first; ascending = biggest loss first.
    if realmTable then
      local realmRowsData = {}
      if record.profitByRealm then
        for realm, data in pairs(record.profitByRealm) do
          realmRowsData[#realmRowsData + 1] = {
            realm  = realm,
            sold   = data.salesCount    or 0,
            bought = data.purchaseCount or 0,
            net    = data.netProfit     or 0,
          }
        end
      end
      realmTable:SetData(realmRowsData)
    end

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

  -- Enable the Lifecycle drill-down button once a successful lookup has
  -- happened. We don't have a direct hook into Research:GetRecord success,
  -- so we enable it any time LookUp is called with non-empty text.
  function page:_setLifecycleEnabled(enabled)
    if enabled then lifecycleBtn:Enable() else lifecycleBtn:Disable() end
  end

  function page:LookUp(text)
    if not text or text == "" then return end
    input:SetText(text)
    input:ClearFocus()
    if not (ns.Research and ns.Research.GetRecord) then return end
    local record = ns.Research:GetRecord(text)
    applyRecord(record)
    self:_setLifecycleEnabled(record and record.itemID and record.itemID > 0)
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
