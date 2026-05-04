-- Tally — UI/CompareLedgersPage.lua
--
-- Side-by-side ledger source comparison. Primary motivation: TLY-24 (TSM
-- vs Tally undercount) — give users (and us) a structured way to see
-- exactly where two sources diverge instead of guessing from chat
-- printouts. Generalized so any pair of registered sources works:
-- TSM ↔ Native, Native ↔ Journalator, FlipQueue ↔ Journalator, etc.
--
-- TLY-27. Driven by ns.Ledger:Compare(sourceA, sourceB).
--
-- Layout:
--   - Top row: source A / source B dropdowns, "Refresh" button
--   - Summary card: row counts, gross-copper totals, delta, match-tier
--     breakdown (strict / loose / fuzzy / unique)
--   - Two-column ScrollTable: aligned diffs

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

local TIER_COLOR = {
  strict = "|cff7fffae",
  loose  = "|cffffd070",
  name   = "|cffffb050",
  fuzzy  = "|cffff8c40",
  unique = "|cffff6666",
}

local function formatTier(t)
  return (TIER_COLOR[t] or "|cff999999") .. (t or "?") .. "|r"
end

-- Custom dropdown — Cogworks doesn't currently expose a generic dropdown
-- primitive; UIDropDownMenuTemplate is fine for this debug-oriented view.
local function makeDropdown(parent, width, sources, getter, setter)
  local dd = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
  UIDropDownMenu_SetWidth(dd, width)
  UIDropDownMenu_Initialize(dd, function(self, level)
    for _, s in ipairs(sources) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = s.label
      info.value = s.name
      info.checked = (s.name == getter())
      info.func = function()
        setter(s.name)
        UIDropDownMenu_SetSelectedValue(dd, s.name)
        UIDropDownMenu_SetText(dd, s.label)
      end
      UIDropDownMenu_AddButton(info, level)
    end
  end)
  return dd
end

function ns.UI.CreateCompareLedgersPage(parent)
  local page = CreateFrame("Frame", nil, parent)

  -- Build the dropdown source list. The "Tally Ledger (all)" entry is a
  -- virtual source representing the entire ledger contents — selecting
  -- it on either side answers "what's in my ledger overall?" against
  -- whatever real source is on the other side. The most useful default:
  -- compare each real source against the ledger so the user can see
  -- "would re-importing pull anything new in?"
  local realSources = (ns.Ledger and ns.Ledger:GetSources()) or {}
  local LEDGER_PSEUDO = ns.Ledger and ns.Ledger.PSEUDO_SOURCE_LEDGER or "__ledger"
  local sources = {
    { name = LEDGER_PSEUDO, label = "Tally Ledger (all)" },
  }
  for _, s in ipairs(realSources) do
    sources[#sources + 1] = s
  end

  -- Default: ledger on the left, first real source on the right.
  local state = {
    sourceA = LEDGER_PSEUDO,
    sourceB = (realSources[1] and realSources[1].name) or LEDGER_PSEUDO,
  }

  -- ============================================================================
  -- Top row: source pickers
  -- ============================================================================

  local row = CreateFrame("Frame", nil, page)
  row:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
  row:SetPoint("TOPRIGHT", page, "TOPRIGHT", 0, 0)
  row:SetHeight(36)

  local labelA = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  labelA:SetPoint("LEFT", row, "LEFT", 0, 0)
  labelA:SetText("Source A:")

  local ddA = makeDropdown(row, 140, sources,
    function() return state.sourceA end,
    function(name) state.sourceA = name; if page.Refresh then page:Refresh() end end)
  ddA:SetPoint("LEFT", labelA, "RIGHT", -8, -2)
  if state.sourceA then
    UIDropDownMenu_SetSelectedValue(ddA, state.sourceA)
    for _, s in ipairs(sources) do
      if s.name == state.sourceA then UIDropDownMenu_SetText(ddA, s.label) end
    end
  end

  local labelB = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  labelB:SetPoint("LEFT", ddA, "RIGHT", 4, 2)
  labelB:SetText("Source B:")

  local ddB = makeDropdown(row, 140, sources,
    function() return state.sourceB end,
    function(name) state.sourceB = name; if page.Refresh then page:Refresh() end end)
  ddB:SetPoint("LEFT", labelB, "RIGHT", -8, -2)
  if state.sourceB then
    UIDropDownMenu_SetSelectedValue(ddB, state.sourceB)
    for _, s in ipairs(sources) do
      if s.name == state.sourceB then UIDropDownMenu_SetText(ddB, s.label) end
    end
  end

  local refreshBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  refreshBtn:SetSize(80, 22)
  refreshBtn:SetPoint("LEFT", ddB, "RIGHT", 0, 2)
  refreshBtn:SetText("Refresh")
  refreshBtn:SetScript("OnClick", function() if page.Refresh then page:Refresh() end end)

  local exportBtn = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
  exportBtn:SetSize(110, 22)
  exportBtn:SetPoint("LEFT", refreshBtn, "RIGHT", 6, 0)
  exportBtn:SetText("Export to chat")

  -- "Hide expire/cancel" toggle — strips rows where copper == 0 from the
  -- export sample + bucket counts. Most divergence in real-world Compare
  -- runs is dominated by AH cancels/expires (high volume, zero copper); this
  -- lets a debugger focus on the rows that actually move money.
  state.hideExpireCancel = state.hideExpireCancel or false
  local hideZeroCheck = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
  hideZeroCheck:SetSize(22, 22)
  hideZeroCheck:SetPoint("LEFT", exportBtn, "RIGHT", 4, 0)
  hideZeroCheck:SetChecked(state.hideExpireCancel)
  hideZeroCheck.text = hideZeroCheck:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  hideZeroCheck.text:SetPoint("LEFT", hideZeroCheck, "RIGHT", 0, 1)
  hideZeroCheck.text:SetText("Hide expire/cancel in export")
  hideZeroCheck:SetScript("OnClick", function(self)
    state.hideExpireCancel = self:GetChecked() and true or false
  end)

  -- ============================================================================
  -- Summary card
  -- ============================================================================

  local summary = CreateFrame("Frame", nil, page, "BackdropTemplate")
  summary:SetPoint("TOPLEFT", row, "BOTTOMLEFT", 0, -8)
  summary:SetPoint("TOPRIGHT", row, "BOTTOMRIGHT", 0, -8)
  summary:SetHeight(70)
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
  sumText:SetText("(pick two sources to compare)")

  -- ============================================================================
  -- Diff table
  -- ============================================================================

  local cw = getCogworks()
  local tableHost = CreateFrame("Frame", nil, page)
  tableHost:SetPoint("TOPLEFT", summary, "BOTTOMLEFT", 0, -8)
  tableHost:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)

  local scrollTable
  if cw and cw.CreateScrollTable then
    scrollTable = cw:CreateScrollTable(tableHost, {
      { key = "tier",    label = "MATCH",   width = 60,  sortable = true, format = formatTier },
      { key = "atTime",  label = "TIME",    width = 100, sortable = true,
        format = function(t) return t and date("%m/%d %H:%M", t) or "—" end },
      { key = "char",    label = "CHAR",    width = 130, sortable = true },
      { key = "kind",    label = "KIND",    width = 80,  sortable = true },
      { key = "item",    label = "ITEM",    width = 90,  sortable = true,
        format = function(v) return v == 0 and "—" or tostring(v) end },
      { key = "aCopper", label = "A",       width = 90,  sortable = true, align = "RIGHT", format = formatGoldShort },
      { key = "bCopper", label = "B",       width = 90,  sortable = true, align = "RIGHT", format = formatGoldShort },
      { key = "delta",   label = "Δ",       width = 90,  sortable = true, align = "RIGHT",
        format = function(v)
          if v == 0 then return "|cff999999—|r" end
          if v > 0 then return "|cff4cd64c+" .. formatGoldShort(v) .. "|r"
          else return "|cffff6666-" .. formatGoldShort(-v) .. "|r" end
        end },
    })
  end

  -- ============================================================================
  -- Refresh
  -- ============================================================================

  local lastPairs, lastStats = {}, {}

  function page:Refresh()
    if not (ns.Ledger and ns.Ledger.Compare) then return end
    if not state.sourceA or not state.sourceB then return end

    local pairs_, stats = ns.Ledger:Compare(state.sourceA, state.sourceB)
    lastPairs, lastStats = pairs_, stats

    local sumLine = string.format(
      "|cff7fbfff%s|r: %d entries (%s)  •  |cff7fbfff%s|r: %d entries (%s)  •  Δ %s",
      state.sourceA, stats.aCount or 0, formatGoldShort(stats.aCopper),
      state.sourceB, stats.bCount or 0, formatGoldShort(stats.bCopper),
      formatGoldShort(stats.deltaCopper))
    local matchLine = string.format(
      "Matches: %s%d strict|r  •  %s%d loose|r  •  %s%d name|r  •  %s%d fuzzy|r  •  %s%d in A only|r  •  %s%d in B only|r",
      TIER_COLOR.strict, stats.strict,
      TIER_COLOR.loose, stats.loose,
      TIER_COLOR.name, stats.name or 0,
      TIER_COLOR.fuzzy, stats.fuzzy,
      TIER_COLOR.unique, stats.aOnly,
      TIER_COLOR.unique, stats.bOnly)
    sumText:SetText(sumLine .. "\n" .. matchLine)

    if scrollTable then
      local rows = {}
      for _, p in ipairs(pairs_) do
        local rep = p.a or p.b
        if rep then
          local aCopper = (p.a and p.a.copper) or 0
          local bCopper = (p.b and p.b.copper) or 0
          rows[#rows + 1] = {
            tier    = p.tier,
            atTime  = rep.atTime,
            char    = rep.charKey or "",
            kind    = rep.kind or "",
            item    = rep.itemID or 0,
            aCopper = aCopper,
            bCopper = bCopper,
            delta   = aCopper - bCopper,
            _sortAtTime  = rep.atTime or 0,
            _sortDelta   = aCopper - bCopper,
            _sortACopper = aCopper,
            _sortBCopper = bCopper,
          }
        end
      end
      table.sort(rows, function(a, b) return (a._sortAtTime or 0) > (b._sortAtTime or 0) end)
      scrollTable:SetData(rows)
    end
  end

  exportBtn:SetScript("OnClick", function()
    print(string.format("|cff7fbfffTally Compare:|r %s vs %s",
      state.sourceA or "?", state.sourceB or "?"))
    print(string.format("  A: %d entries (%s); B: %d entries (%s); Δ %s",
      lastStats.aCount or 0, formatGoldShort(lastStats.aCopper or 0),
      lastStats.bCount or 0, formatGoldShort(lastStats.bCopper or 0),
      formatGoldShort(lastStats.deltaCopper or 0)))
    print(string.format("  matches: strict=%d loose=%d name=%d fuzzy=%d a-only=%d b-only=%d",
      lastStats.strict or 0, lastStats.loose or 0, lastStats.name or 0,
      lastStats.fuzzy or 0, lastStats.aOnly or 0, lastStats.bOnly or 0))

    local hideZero = state.hideExpireCancel and true or false

    local function formatRow(side, e)
      return string.format("  [%s] %s | %s | %s | %s | item:%s | %s",
        side,
        e.atTime and date("%m/%d %H:%M", e.atTime) or "?",
        e.source or "?",
        e.kind or "?",
        e.charKey or "?",
        tostring(e.itemID or "?"),
        formatGoldShort(e.copper or 0))
    end

    local function bucketLine(label, counts)
      local parts = {}
      for k, n in pairs(counts) do parts[#parts + 1] = k .. "=" .. n end
      table.sort(parts)
      if #parts == 0 then return label .. ": (none)" end
      return label .. ": " .. table.concat(parts, ", ")
    end

    local function collectSide(predicate)
      local sample, byKind, bySource = {}, {}, {}
      for _, p in ipairs(lastPairs) do
        local e = predicate(p)
        if e and not (hideZero and (e.copper or 0) == 0) then
          if #sample < 5 then sample[#sample + 1] = e end
          local k, s = e.kind or "?", e.source or "?"
          byKind[k] = (byKind[k] or 0) + 1
          bySource[s] = (bySource[s] or 0) + 1
        end
      end
      return sample, byKind, bySource
    end

    local aSample, aByKind, aBySource = collectSide(function(p) return p.a and not p.b and p.a or nil end)
    local bSample, bByKind, bBySource = collectSide(function(p) return p.b and not p.a and p.b or nil end)

    local hideNote = hideZero and ", expire/cancel hidden" or ""
    print(string.format("  --- A-only sample (top %d%s) ---", #aSample, hideNote))
    for _, e in ipairs(aSample) do print(formatRow("A-only", e)) end
    print("  " .. bucketLine("A-only by kind", aByKind))
    print("  " .. bucketLine("A-only by source", aBySource))
    print(string.format("  --- B-only sample (top %d%s) ---", #bSample, hideNote))
    for _, e in ipairs(bSample) do print(formatRow("B-only", e)) end
    print("  " .. bucketLine("B-only by kind", bByKind))
    print("  " .. bucketLine("B-only by source", bBySource))
  end)

  page:Refresh()

  return page
end
