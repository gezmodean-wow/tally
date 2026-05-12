-- Tally — UI/LifecyclePage.lua
--
-- Per-item lifecycle drill-down. Users land here from the Research panel
-- ("View Lifecycle →" button) or via the tab strip directly. The page
-- answers "what happened to this item across all my postings, and what
-- did it net me?" Visually it has three regions:
--
--   1. Item header (icon, name, ID, ownership at-a-glance)
--   2. Analysis card — postings count, sale-vs-fail breakdown, total
--      revenue/fees/deposit-forfeit/net, avg time-to-sell, pricing trend
--   3. Cohort table — one row per AH listing, click to expand details
--
-- TLY-26. Driven by ns.Lifecycle:Analyze(itemID).

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

local function formatDuration(sec)
  if not sec or sec <= 0 then return "—" end
  if sec < 3600 then return string.format("%dm", math.floor(sec / 60)) end
  if sec < 86400 then return string.format("%.1fh", sec / 3600) end
  return string.format("%.1fd", sec / 86400)
end

local function trendBadge(trend)
  if trend == "improving" then return "|cff4cd64c↑ improving|r"
  elseif trend == "declining" then return "|cffff6666↓ declining|r"
  else return "|cff999999→ flat|r" end
end

local function statusColor(status)
  if status == "sold" then return themeColor("success", { 0.30, 0.85, 0.30, 1 })
  elseif status == "expired" or status == "cancelled" then return themeColor("error", { 1, 0.40, 0.40, 1 })
  elseif status == "partial" then return themeColor("brass", { 0.83, 0.63, 0.09, 1 })
  end
  return themeColor("textDim", { 0.6, 0.6, 0.6, 1 })
end

local function makeStatLabel(parent, anchor, anchorPoint, label, value, valueColor)
  local container = CreateFrame("Frame", nil, parent)
  container:SetSize(140, 32)
  container:SetPoint("TOPLEFT", anchor, anchorPoint, 0, 0)

  local lbl = container:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  lbl:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
  lbl:SetText(label)

  local val = container:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  val:SetPoint("TOPLEFT", lbl, "BOTTOMLEFT", 0, -2)
  val:SetText(value or "—")
  if valueColor then val:SetTextColor(valueColor[1], valueColor[2], valueColor[3], valueColor[4] or 1) end
  container.label = lbl
  container.value = val
  return container
end

function ns.UI.CreateLifecyclePage(parent)
  local page = CreateFrame("Frame", nil, parent)

  local state = { itemID = nil, itemLink = nil, itemName = nil, costBasisMethod = "fifo" }

  -- ============================================================================
  -- Top row: item lookup + cost basis toggle
  -- ============================================================================

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

  -- Cost basis toggle (FIFO ↔ Avg).
  local methodLabel = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  methodLabel:SetPoint("LEFT", lookupBtn, "RIGHT", 18, 0)
  methodLabel:SetText("Cost basis:")

  local methodBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  methodBtn:SetSize(70, 22)
  methodBtn:SetPoint("LEFT", methodLabel, "RIGHT", 6, 0)
  methodBtn:SetText("FIFO")

  -- ============================================================================
  -- Item header
  -- ============================================================================

  local header = CreateFrame("Frame", nil, page)
  header:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -10)
  header:SetPoint("TOPRIGHT", row, "BOTTOMRIGHT", 0, -10)
  header:SetHeight(40)

  local icon = header:CreateTexture(nil, "ARTWORK")
  icon:SetSize(32, 32)
  icon:SetPoint("LEFT", header, "LEFT", 0, 0)
  icon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")

  local nameText = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  nameText:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, 0)
  nameText:SetText("(enter an item link or ID)")

  local subText = header:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  subText:SetPoint("TOPLEFT", nameText, "BOTTOMLEFT", 0, -4)
  subText:SetText("")

  -- ============================================================================
  -- Analysis card
  -- ============================================================================

  local analysisHdr = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  analysisHdr:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -14)
  analysisHdr:SetText("ANALYSIS")
  analysisHdr:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local analysisRule = page:CreateTexture(nil, "ARTWORK")
  analysisRule:SetPoint("TOPLEFT", analysisHdr, "BOTTOMLEFT", 0, -2)
  analysisRule:SetPoint("RIGHT", page, "RIGHT", 0, 0)
  analysisRule:SetHeight(1)
  analysisRule:SetColorTexture(themeColor("border", { 0.30, 0.30, 0.40, 0.6 }))

  -- Stat grid: 4 columns × 2 rows.
  local grid = CreateFrame("Frame", nil, page)
  grid:SetPoint("TOPLEFT", analysisRule, "BOTTOMLEFT", 0, -8)
  grid:SetPoint("TOPRIGHT", analysisRule, "BOTTOMRIGHT", 0, -8)
  grid:SetHeight(72)

  local statPostings   = makeStatLabel(grid, grid, "TOPLEFT", "POSTINGS", "—")
  local statSold       = makeStatLabel(grid, statPostings, "TOPRIGHT", "SOLD / FAILED", "—")
  statSold:SetPoint("TOPLEFT", statPostings, "TOPRIGHT", 16, 0)
  local statRevenue    = makeStatLabel(grid, statSold, "TOPRIGHT", "REVENUE", "—")
  statRevenue:SetPoint("TOPLEFT", statSold, "TOPRIGHT", 16, 0)
  local statNet        = makeStatLabel(grid, statRevenue, "TOPRIGHT", "NET PROFIT", "—")
  statNet:SetPoint("TOPLEFT", statRevenue, "TOPRIGHT", 16, 0)

  local statTimeToSell = makeStatLabel(grid, statPostings, "BOTTOMLEFT", "AVG TIME TO SELL", "—")
  statTimeToSell:SetPoint("TOPLEFT", statPostings, "BOTTOMLEFT", 0, -8)
  local statBestPrice  = makeStatLabel(grid, statTimeToSell, "TOPRIGHT", "BEST LIST PRICE", "—")
  statBestPrice:SetPoint("TOPLEFT", statTimeToSell, "TOPRIGHT", 16, 0)
  local statFeesLost   = makeStatLabel(grid, statBestPrice, "TOPRIGHT", "FEES + DEPOSITS LOST", "—")
  statFeesLost:SetPoint("TOPLEFT", statBestPrice, "TOPRIGHT", 16, 0)
  local statTrend      = makeStatLabel(grid, statFeesLost, "TOPRIGHT", "PRICING TREND", "—")
  statTrend:SetPoint("TOPLEFT", statFeesLost, "TOPRIGHT", 16, 0)

  local infoLine = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  infoLine:SetPoint("TOPLEFT", grid, "BOTTOMLEFT", 0, -6)
  infoLine:SetPoint("RIGHT", page, "RIGHT", 0, 0)
  infoLine:SetJustifyH("LEFT")
  infoLine:SetText("")

  -- ============================================================================
  -- Cohort table
  -- ============================================================================

  local cw = getCogworks()
  local tableHdr = page:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  tableHdr:SetPoint("TOPLEFT", infoLine, "BOTTOMLEFT", 0, -10)
  tableHdr:SetText("COHORTS — ONE ROW PER LISTING")
  tableHdr:SetTextColor(themeColor("brass", { 0.83, 0.63, 0.09, 1 }))

  local tableRule = page:CreateTexture(nil, "ARTWORK")
  tableRule:SetPoint("TOPLEFT", tableHdr, "BOTTOMLEFT", 0, -2)
  tableRule:SetPoint("RIGHT", page, "RIGHT", 0, 0)
  tableRule:SetHeight(1)
  tableRule:SetColorTexture(themeColor("border", { 0.30, 0.30, 0.40, 0.6 }))

  local tableHost = CreateFrame("Frame", nil, page)
  tableHost:SetPoint("TOPLEFT", tableRule, "BOTTOMLEFT", 0, -4)
  tableHost:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 110)

  local function formatStatusCell(s)
    local r, g, b = statusColor(s)
    return string.format("|cff%02x%02x%02x%s|r",
      math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), s or "?")
  end

  local function formatCohortAmount(v)
    if not v or v == 0 then return "|cff999999—|r" end
    if v > 0 then return "|cff4cd64c+" .. formatGoldShort(v) .. "|r"
    else return "|cffff6666-" .. formatGoldShort(-v) .. "|r" end
  end

  local scrollTable
  if cw and cw.CreateScrollTable then
    scrollTable = cw:CreateScrollTable(tableHost, {
      { key = "posted",  label = "POSTED",  width = 100, sortable = true },
      { key = "char",    label = "CHAR",    width = 130, sortable = true },
      { key = "count",   label = "QTY",     width = 50,  sortable = true, align = "RIGHT" },
      { key = "buyout",  label = "BUYOUT",  width = 100, sortable = true, align = "RIGHT", format = formatGoldShort },
      { key = "deposit", label = "DEPOSIT", width = 90,  sortable = true, align = "RIGHT", format = formatGoldShort },
      { key = "status",  label = "STATUS",  width = 80,  sortable = true, format = formatStatusCell },
      { key = "net",     label = "NET",     width = 100, sortable = true, align = "RIGHT", format = formatCohortAmount },
      { key = "time",    label = "TIME",    width = 70,  sortable = true, align = "RIGHT" },
    })
    scrollTable:SetSort("posted", false) -- newest first
  end

  -- ============================================================================
  -- Drill-down panel (below the table)
  -- ============================================================================

  local detail = CreateFrame("Frame", nil, page, "BackdropTemplate")
  detail:SetPoint("TOPLEFT", tableHost, "BOTTOMLEFT", 0, -6)
  detail:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
  detail:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    edgeSize = 1,
  })
  detail:SetBackdropColor(themeColor("bgDark", { 0.04, 0.04, 0.07, 0.7 }))
  detail:SetBackdropBorderColor(themeColor("border", { 0.30, 0.30, 0.40, 1 }))

  local detailTitle = detail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  detailTitle:SetPoint("TOPLEFT", detail, "TOPLEFT", 8, -6)
  detailTitle:SetText("Click a cohort row to see its detail")

  local detailBody = detail:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  detailBody:SetPoint("TOPLEFT", detailTitle, "BOTTOMLEFT", 0, -4)
  detailBody:SetPoint("BOTTOMRIGHT", detail, "BOTTOMRIGHT", -8, 6)
  detailBody:SetJustifyH("LEFT")
  detailBody:SetJustifyV("TOP")
  detailBody:SetSpacing(2)
  detailBody:SetText("")

  -- ============================================================================
  -- Refresh
  -- ============================================================================

  local function clearStats()
    statPostings.value:SetText("—")
    statSold.value:SetText("—")
    statRevenue.value:SetText("—")
    statNet.value:SetText("—")
    statTimeToSell.value:SetText("—")
    statBestPrice.value:SetText("—")
    statFeesLost.value:SetText("—")
    statTrend.value:SetText("—")
    infoLine:SetText("")
    if scrollTable then scrollTable:SetData({}) end
    detailTitle:SetText("Click a cohort row to see its detail")
    detailBody:SetText("")
  end

  local function refresh()
    if not state.itemID or not ns.Lifecycle then
      clearStats(); return
    end

    local analysis, cohorts = ns.Lifecycle:Analyze(state.itemID,
      { costBasisMethod = state.costBasisMethod })

    -- Header
    if state.itemLink then
      local _, _, _, _, _, _, _, _, _, texture = GetItemInfo(state.itemLink)
      if texture then icon:SetTexture(texture) end
    elseif state.itemID then
      local _, _, _, _, _, _, _, _, _, texture = GetItemInfo(state.itemID)
      if texture then icon:SetTexture(texture) end
    end
    nameText:SetText(state.itemName or state.itemLink or ("item:" .. state.itemID))
    subText:SetText(string.format("itemID %d  •  cost basis: %s",
      state.itemID, state.costBasisMethod:upper()))

    -- Analysis values
    statPostings.value:SetText(tostring(analysis.cohortCount))
    statSold.value:SetText(string.format("%d / %d",
      analysis.soldCohorts,
      analysis.expiredCohorts + analysis.cancelledCohorts))
    statRevenue.value:SetText(formatGoldShort(analysis.totalRevenue))

    statNet.value:SetText(formatCohortAmount(analysis.netProfit))
    if analysis.netProfit >= 0 then
      statNet.value:SetTextColor(themeColor("success", { 0.30, 0.85, 0.30, 1 }))
    else
      statNet.value:SetTextColor(themeColor("error", { 1, 0.40, 0.40, 1 }))
    end

    statTimeToSell.value:SetText(formatDuration(analysis.avgTimeToSellSec))
    statBestPrice.value:SetText(formatGoldShort(analysis.bestListPriceCopper or 0))
    statFeesLost.value:SetText(formatGoldShort(
      (analysis.totalFeesPaid or 0) + (analysis.totalDepositForfeit or 0)))
    statTrend.value:SetText(trendBadge(analysis.pricingTrend))

    -- Info line
    local info = analysis.info or {}
    local notes = {}
    if not info.hasDeposits and info.syntheticCount > 0 then
      notes[#notes + 1] = string.format(
        "|cffffd070note:|r %d cohorts inferred from sale/expire rows — install Journalator for full ah-deposit tracking and post-attempt counts.",
        info.syntheticCount)
    end
    if info.unmatchedSales > 0 then
      notes[#notes + 1] = string.format(
        "|cff999999%d unmatched sale rows — likely pre-existing inventory the ledger didn't see purchased.|r",
        info.unmatchedSales)
    end
    if analysis.totalCostBasis == 0 and analysis.totalRevenue > 0 then
      notes[#notes + 1] = "|cff999999No purchase rows in ledger; cost basis = 0 (raw revenue shown).|r"
    end
    infoLine:SetText(table.concat(notes, "\n"))

    -- Cohort rows
    if scrollTable then
      local rows = {}
      for _, c in ipairs(cohorts) do
        local r = {
          posted   = c.postedAt and date("%m/%d %H:%M", c.postedAt) or "?",
          char     = c.charKey or "",
          count    = c.count or 1,
          buyout   = c.buyout or 0,
          deposit  = c.deposit or 0,
          status   = c.status,
          net      = c.netRealized or 0,
          time     = c.daysActive and formatDuration(c.daysActive * 86400) or "—",
          _sortPosted  = c.postedAt or 0,
          _sortBuyout  = c.buyout or 0,
          _sortDeposit = c.deposit or 0,
          _sortNet     = c.netRealized or 0,
          _sortTime    = c.daysActive or 0,
          _cohort = c,  -- referenced by the row click handler
        }
        rows[#rows + 1] = r
      end
      scrollTable:SetData(rows)
    end
  end

  -- ============================================================================
  -- Cohort drill-down: click handler
  -- ============================================================================

  local function showCohortDetail(c)
    if not c then return end
    detailTitle:SetText(string.format("Cohort posted %s by %s — %s",
      c.postedAt and date("%Y-%m-%d %H:%M", c.postedAt) or "?",
      c.charKey or "?",
      c.status))
    local lines = {}
    lines[#lines + 1] = string.format("Listed: %d × %s buyout, deposit %s",
      c.count or 1,
      formatGoldShort(c.buyout or 0),
      formatGoldShort(c.deposit or 0))
    if #c.sales > 0 then
      lines[#lines + 1] = string.format("Sales: %d row(s); revenue %s; fees paid %s",
        #c.sales, formatGoldShort(c.revenue), formatGoldShort(c.feesPaid))
      for i, s in ipairs(c.sales) do
        lines[#lines + 1] = string.format("  • %s — %d × %s = %s",
          s.atTime and date("%m/%d %H:%M", s.atTime) or "?",
          s.count or 1,
          formatGoldShort((s.copper or 0) / math.max(s.count or 1, 1)),
          formatGoldShort(s.copper or 0))
      end
    end
    if c.expire then
      lines[#lines + 1] = string.format("Expired %s — deposit forfeit %s",
        c.expire.atTime and date("%m/%d %H:%M", c.expire.atTime) or "?",
        formatGoldShort(c.depositForfeit))
    elseif c.cancel then
      lines[#lines + 1] = string.format("Cancelled %s — deposit forfeit (commodity 5%%) %s",
        c.cancel.atTime and date("%m/%d %H:%M", c.cancel.atTime) or "?",
        formatGoldShort(c.depositForfeit))
    end
    if c.costBasis and c.costBasis > 0 then
      lines[#lines + 1] = string.format("Cost basis (%s): %s",
        state.costBasisMethod:upper(), formatGoldShort(c.costBasis))
    end
    lines[#lines + 1] = string.format("Net realized: %s", formatCohortAmount(c.netRealized))
    if c.synthetic then
      lines[#lines + 1] = "|cffffd070(synthetic — no paired ah-deposit row; install Journalator for full data)|r"
    end
    detailBody:SetText(table.concat(lines, "\n"))
  end

  if scrollTable and scrollTable.SetOnRowClick then
    scrollTable:SetOnRowClick(function(rowData) showCohortDetail(rowData and rowData._cohort) end)
  end

  -- ============================================================================
  -- Lookup wiring
  -- ============================================================================

  local function lookup(text)
    text = text or input:GetText()
    if not text or text == "" then return end

    local itemID, itemLink, itemName

    -- Hyperlink: pull ID + name from GetItemInfo.
    if text:find("|H") then
      itemLink = text
      itemID = tonumber(text:match("|Hitem:(%d+)"))
      itemName = text:match("%[(.-)%]") or text
    elseif text:match("^%d+$") then
      itemID = tonumber(text)
      itemName = GetItemInfo(itemID) or ("item:" .. itemID)
      itemLink = nil
    else
      -- Treat as a name lookup via GetItemInfo (works for cached items).
      local name, link = GetItemInfo(text)
      if name then
        itemName = name
        itemLink = link
        itemID = link and tonumber(link:match("|Hitem:(%d+)"))
      end
    end

    if not itemID then
      if ns.Output then
        ns.Output:Error("Could not resolve '" .. text .. "' to an item ID.")
      end
      return
    end
    state.itemID = itemID
    state.itemLink = itemLink
    state.itemName = itemName
    refresh()
  end

  lookupBtn:SetScript("OnClick", function() lookup() end)
  input:SetScript("OnEnterPressed", function(self) lookup(self:GetText()); self:ClearFocus() end)

  methodBtn:SetScript("OnClick", function()
    state.costBasisMethod = state.costBasisMethod == "fifo" and "avg" or "fifo"
    methodBtn:SetText(state.costBasisMethod == "fifo" and "FIFO" or "Avg")
    refresh()
  end)

  function page:LookUp(text)
    input:SetText(text or "")
    lookup(text)
  end

  function page:Refresh() refresh() end

  return page
end

-- Convenience function used by ResearchPage's "View Lifecycle →" button and
-- by the slash command. Opens the main frame, switches to the Lifecycle tab,
-- runs the lookup.
function ns.UI.ShowLifecycle(input)
  if not (ns.UI.MainFrame and ns.UI.MainFrame.Show) then return end
  ns.UI.MainFrame:Show()
  if ns.UI.MainFrame.ShowPage then
    ns.UI.MainFrame:ShowPage("Lifecycle")
  end
  if input and input ~= "" then
    local page = ns.UI.MainFrame.GetPage and ns.UI.MainFrame:GetPage("Lifecycle")
    if page and page.LookUp then page:LookUp(input) end
  end
end
