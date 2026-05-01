-- Tally — UI/InventoryPage.lua
--
-- Per-character inventory drill-down. Answers the user-flagged gap
-- "I can see my net worth total but I can't see what makes it up." Each
-- row is one (item, char) pair carrying location breakdown, quantity,
-- unit price, total value, and share of net worth. Filter by character
-- (or All / Warband), toggle Saleable vs Owned, sortable on every column.
--
-- Public surface:
--   page = ns.UI.CreateInventoryPage(parent)
--   page:FilterCharacter(charKey)  -- drives the char-filter dropdown
--   ns.UI.ShowInventory(charKey)   -- shows main frame, switches tab,
--                                     applies filter

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

local LOC_ORDER = { "bags", "reagent", "bank", "mail", "equipped", "void", "auctions", "warbank" }

local function formatLocations(locations)
  if not locations then return "" end
  local parts = {}
  for _, loc in ipairs(LOC_ORDER) do
    local n = locations[loc]
    if n and n > 0 then
      parts[#parts + 1] = string.format("%s %d", loc, n)
    end
  end
  return table.concat(parts, ", ")
end

-- Resolve item display text from itemID + cached GetItemInfo. Falls back
-- to "item:N" when the item isn't yet cached (fresh-install on a long
-- inactive char) so the row doesn't render empty.
local function itemLabel(itemID)
  if not itemID then return "?" end
  local name = GetItemInfo(itemID)
  return name or ("item:" .. itemID)
end

local function itemColor(itemID)
  if not itemID then return 1, 1, 1 end
  local _, _, quality = GetItemInfo(itemID)
  if quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality] then
    local c = ITEM_QUALITY_COLORS[quality]
    return c.r, c.g, c.b
  end
  return 1, 1, 1
end

-- Custom dropdown using UIDropDownMenu (same pattern as CompareLedgersPage).
local function makeDropdown(parent, width, items, getter, setter)
  local dd = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
  UIDropDownMenu_SetWidth(dd, width)
  UIDropDownMenu_Initialize(dd, function(self, level)
    for _, it in ipairs(items) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = it.label
      info.value = it.value
      info.checked = (it.value == getter())
      info.func = function()
        setter(it.value)
        UIDropDownMenu_SetSelectedValue(dd, it.value)
        UIDropDownMenu_SetText(dd, it.label)
      end
      UIDropDownMenu_AddButton(info, level)
    end
  end)
  return dd
end

function ns.UI.CreateInventoryPage(parent)
  local page = CreateFrame("Frame", nil, parent)
  local state = {
    charFilter = "__all",   -- "__all" | "Warband" | "<charKey>"
    includeBound = false,
  }

  -- ============================================================================
  -- Top control row
  -- ============================================================================

  local row = CreateFrame("Frame", nil, page)
  row:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
  row:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 0)
  row:SetHeight(36)

  local charLabel = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  charLabel:SetPoint("LEFT", row, "LEFT", 0, 0)
  charLabel:SetText("Character:")

  -- Char items get rebuilt on each Refresh — the inventory rollup may
  -- have new chars after backfill. Build once with placeholder so the
  -- dropdown frame exists; re-populate in rebuildCharOptions().
  local dd = CreateFrame("Frame", nil, row, "UIDropDownMenuTemplate")
  UIDropDownMenu_SetWidth(dd, 180)
  dd:SetPoint("LEFT", charLabel, "RIGHT", -8, -2)

  local function rebuildCharOptions()
    local items = { { label = "All characters", value = "__all" } }
    local rollup = ns.Inventory and ns.Inventory:Get() or nil
    local chars = {}
    if rollup and rollup.characters then
      for charKey in pairs(rollup.characters) do
        chars[#chars + 1] = charKey
      end
    end
    table.sort(chars)
    for _, c in ipairs(chars) do
      items[#items + 1] = { label = c, value = c }
    end
    if rollup and rollup.warband then
      items[#items + 1] = { label = "Warband", value = "Warband" }
    end

    UIDropDownMenu_Initialize(dd, function(self, level)
      for _, it in ipairs(items) do
        local info = UIDropDownMenu_CreateInfo()
        info.text = it.label
        info.value = it.value
        info.checked = (it.value == state.charFilter)
        info.func = function()
          state.charFilter = it.value
          UIDropDownMenu_SetSelectedValue(dd, it.value)
          UIDropDownMenu_SetText(dd, it.label)
          page:Refresh()
        end
        UIDropDownMenu_AddButton(info, level)
      end
    end)
    -- Set the displayed text to the current selection's label.
    for _, it in ipairs(items) do
      if it.value == state.charFilter then
        UIDropDownMenu_SetText(dd, it.label)
        break
      end
    end
  end

  -- View toggle (Saleable / Owned)
  local viewLabel = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  viewLabel:SetPoint("LEFT", dd, "RIGHT", 8, 2)
  viewLabel:SetText("View:")

  local viewBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  viewBtn:SetSize(80, 22)
  viewBtn:SetPoint("LEFT", viewLabel, "RIGHT", 6, 0)
  viewBtn:SetText("Saleable")

  -- ============================================================================
  -- Summary card
  -- ============================================================================

  local summary = CreateFrame("Frame", nil, page, "BackdropTemplate")
  summary:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -8)
  summary:SetPoint("TOPRIGHT", row, "BOTTOMRIGHT", 0, -8)
  summary:SetHeight(40)
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
  sumText:SetJustifyV("MIDDLE")
  sumText:SetText("(no inventory)")

  -- ============================================================================
  -- Item table
  -- ============================================================================

  local cw = getCogworks()
  local tableHost = CreateFrame("Frame", nil, page)
  tableHost:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -8)
  tableHost:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)

  local scrollTable
  if cw and cw.CreateScrollTable then
    scrollTable = cw:CreateScrollTable(tableHost, {
      { key = "item",   label = "ITEM",   width = 220, sortable = true },
      { key = "char",   label = "CHAR",   width = 140, sortable = true },
      { key = "qty",    label = "QTY",    width = 70,  sortable = true, align = "RIGHT" },
      { key = "loc",    label = "LOC",    width = 160, sortable = true },
      { key = "unit",   label = "UNIT",   width = 90,  sortable = true, align = "RIGHT", format = formatGoldShort },
      { key = "total",  label = "TOTAL",  width = 110, sortable = true, align = "RIGHT", format = formatGoldShort },
      { key = "share",  label = "% NET",  width = 60,  sortable = true, align = "RIGHT",
        format = function(v) return string.format("%.1f%%", v or 0) end },
    })
    scrollTable:SetSort("total", false)  -- biggest first
  end

  -- ============================================================================
  -- Refresh
  -- ============================================================================

  local function valueItemEntry(entry, strategy, includeBound)
    -- Mirror Pricing:ValueItemMap's per-entry logic for one item:
    -- count = saleable or total, unit price via Pricing:GetUnitValue.
    local count = includeBound and (entry.total or 0) or (entry.saleable or 0)
    if count <= 0 or not entry.itemID then return 0, 0, count end
    local unit = ns.Pricing:GetUnitValue(entry.itemID, nil, strategy) or 0
    return unit, unit * count, count
  end

  function page:Refresh()
    if not (ns.Inventory and ns.NetWorth and ns.Pricing) then return end
    rebuildCharOptions()

    local strategy = ns.NetWorth:GetStrategy()
    local includeBound = state.includeBound

    -- Snapshot of net worth for the % NET column. Always computed against
    -- the FULL net worth (regardless of charFilter) so the share number
    -- means "share of total wealth" not "share of this char".
    local netSnap = ns.NetWorth:Snapshot({ includeBound = includeBound })
    local netTotal = math.max(netSnap.total, 1)

    local rollup = ns.Inventory:Get() or {}
    local rows = {}
    local viewTotalCopper, viewTotalCount = 0, 0

    local function emit(charKey, items)
      if type(items) ~= "table" then return end
      if state.charFilter ~= "__all" and state.charFilter ~= charKey then return end
      for itemKey, entry in pairs(items) do
        local unit, total, count = valueItemEntry(entry, strategy, includeBound)
        if count > 0 then
          rows[#rows + 1] = {
            item    = itemLabel(entry.itemID),
            char    = charKey,
            qty     = count,
            loc     = formatLocations(entry.locations),
            unit    = unit,
            total   = total,
            share   = total / netTotal * 100,
            _itemID = entry.itemID,
            _sortItem = itemLabel(entry.itemID):lower(),
            _sortQty  = count,
            _sortUnit = unit,
            _sortTotal = total,
            _sortShare = total / netTotal * 100,
          }
          viewTotalCopper = viewTotalCopper + total
          viewTotalCount = viewTotalCount + 1
        end
      end
    end

    for charKey, char in pairs(rollup.characters or {}) do
      emit(charKey, char.items)
    end
    if rollup.warband then
      emit("Warband", rollup.warband.items)
    end

    if scrollTable then scrollTable:SetData(rows) end

    local label = state.charFilter == "__all" and "all characters"
      or state.charFilter
    local sharePct = (viewTotalCopper / netTotal) * 100
    sumText:SetText(string.format(
      "|cff7fbfff%s|r  -  %d items  -  total %s  -  %.1f%% of %s net worth (%s)",
      label, viewTotalCount, formatGoldShort(viewTotalCopper),
      sharePct,
      includeBound and "owned" or "saleable",
      strategy or "?"))
  end

  -- ============================================================================
  -- Wiring
  -- ============================================================================

  viewBtn:SetScript("OnClick", function()
    state.includeBound = not state.includeBound
    viewBtn:SetText(state.includeBound and "Owned" or "Saleable")
    page:Refresh()
  end)

  -- Public: drill-down entry point. Called when a NetWorthPage char row
  -- is clicked (or by ns.UI.ShowInventory).
  function page:FilterCharacter(charKey)
    state.charFilter = charKey or "__all"
    page:Refresh()
  end

  page:Refresh()
  return page
end

-- Convenience: open the main frame, switch to Inventory tab, apply filter.
function ns.UI.ShowInventory(charKey)
  if not (ns.UI.MainFrame and ns.UI.MainFrame.ShowPage) then return end
  ns.UI.MainFrame:Show()
  ns.UI.MainFrame:ShowPage("Inventory")
  local page = ns.UI.MainFrame.GetPage and ns.UI.MainFrame:GetPage("Inventory")
  if page and page.FilterCharacter then page:FilterCharacter(charKey or "__all") end
end
