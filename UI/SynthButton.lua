-- Tally — UI/SynthButton.lua
--
-- Reusable "Synthesise history" button for the Research / Lifecycle /
-- Compare pages (TLY-71 Flow B). The button:
--   - tooltips with a live coverage probe (missing periods + row estimate)
--   - prompts for confirmation before starting (parses big TSM CSVs)
--   - disables itself + shows a "Synthesising…" label while a job runs
--   - re-enables on done / cancelled / errored
--
-- Synthesis state is singleton at ns.Synthesis, so all instances of this
-- button across pages mirror the same in-flight job. Listener registration
-- happens once per button instance.
--
-- Public surface:
--   btn = ns.UI.CreateSynthButton(parent)
--   btn:SetPoint(...)  — caller anchors

local addonName, ns = ...
ns.UI = ns.UI or {}

local function fmtGroup(n)
  if BreakUpLargeNumbers then return BreakUpLargeNumbers(n) end
  return tostring(n)
end

-- Build the confirm popup once per button — keying the dialog name by the
-- button instance via tostring(btn) keeps multiple page-instances from
-- stomping each other's popup state.
local function showStartConfirm(missing, totalRows, onAccept)
  StaticPopupDialogs["TALLY_SYNTH_START"] = StaticPopupDialogs["TALLY_SYNTH_START"] or {
    text = "TEMPLATE",        -- replaced before each Show()
    button1 = "Synthesise",
    button2 = "Cancel",
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    OnAccept = function() end,
  }
  StaticPopupDialogs["TALLY_SYNTH_START"].text = string.format(
    "Synthesise %d missing period%s from sibling sources?\n\n"
    .. "~%s rows total across all sources. First parse of TSM/Journalator\n"
    .. "can block for a few seconds on big rosters.",
    #missing, #missing == 1 and "" or "s", fmtGroup(totalRows))
  StaticPopupDialogs["TALLY_SYNTH_START"].OnAccept = onAccept
  StaticPopup_Show("TALLY_SYNTH_START")
end

function ns.UI.CreateSynthButton(parent)
  local btn = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  btn:SetSize(150, 22)
  btn:SetText("Synthesise history")

  local function refresh()
    if not (ns.Synthesis and ns.Synthesis.GetState) then
      btn:Disable()
      btn:SetText("Synthesis unavailable")
      return
    end
    local state = ns.Synthesis:GetState()
    if state.phase == "running" then
      btn:Disable()
      btn:SetText("Synthesising…")
    elseif state.phase == "paused" then
      btn:Disable()
      btn:SetText("Synth paused")
    elseif state.phase == "flushing" then
      btn:Disable()
      btn:SetText("Flushing…")
    else
      btn:Enable()
      btn:SetText("Synthesise history")
    end
  end

  btn:SetScript("OnEnter", function(self)
    if not (ns.Synthesis and ns.Synthesis.GetCandidates) then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:SetText("Synthesise historical archives", 1, 1, 1)

    local state = ns.Synthesis:GetState()
    if state.phase ~= "idle" then
      GameTooltip:AddLine("Synthesis in progress.", 0.7, 0.7, 0.7, true)
      if state.currentKey then
        GameTooltip:AddLine("Now: " .. state.currentKey, 0.83, 0.63, 0.09)
      end
      GameTooltip:AddLine(string.format("%d periods queued.", #(state.queue or {})), 0.7, 0.7, 0.7)
      GameTooltip:Show()
      return
    end

    local cands = ns.Synthesis:GetCandidates({})
    if not cands then
      GameTooltip:AddLine("Coverage probe failed.", 1, 0.4, 0.4, true)
      GameTooltip:Show()
      return
    end
    if #cands.sources == 0 then
      GameTooltip:AddLine("No importable sibling sources detected.", 0.7, 0.7, 0.7, true)
      GameTooltip:AddLine("Install TSM Accounting, FlipQueue, or Journalator and reload.", 0.7, 0.7, 0.7, true)
      GameTooltip:Show()
      return
    end

    GameTooltip:AddLine(string.format(
      "Sources: %s", table.concat(cands.sources, ", ")), 0.7, 0.7, 0.7, true)
    GameTooltip:AddLine(" ", 1, 1, 1)
    if #cands.missing == 0 then
      GameTooltip:AddLine("All periods siblings cover already have Tally archives.", 0.30, 0.85, 0.30, true)
    else
      local totalRows = 0
      for _, m in ipairs(cands.missing) do totalRows = totalRows + (m.rows or 0) end
      GameTooltip:AddLine(string.format("Missing periods: %d", #cands.missing), 0.83, 0.63, 0.09)
      GameTooltip:AddLine(string.format("Estimated rows: ~%s", fmtGroup(totalRows)), 0.83, 0.63, 0.09)
      -- Show the first few period keys so the player has a hint of scope.
      local preview = {}
      for i = 1, math.min(4, #cands.missing) do preview[#preview + 1] = cands.missing[i].key end
      if #cands.missing > 4 then preview[#preview + 1] = "…" end
      GameTooltip:AddLine(table.concat(preview, "  "), 0.6, 0.6, 0.6)
    end
    if #cands.existing > 0 then
      GameTooltip:AddLine(string.format("Already archived: %d", #cands.existing), 0.30, 0.85, 0.30)
    end
    if #cands.skippedCurrent > 0 then
      GameTooltip:AddLine("Current month tracked live — not synthesised.", 0.6, 0.6, 0.6, true)
    end
    GameTooltip:Show()
  end)
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  btn:SetScript("OnClick", function()
    if not (ns.Synthesis and ns.Synthesis.EnsurePeriods) then return end
    local cands = ns.Synthesis:GetCandidates({})
    if not cands or #cands.missing == 0 then
      if ns.Output then
        ns.Output:Info("Nothing to synthesise — all periods siblings cover already have Tally archives.")
      end
      return
    end
    local missing = {}
    local totalRows = 0
    for _, m in ipairs(cands.missing) do
      missing[#missing + 1] = m.key
      totalRows = totalRows + (m.rows or 0)
    end
    showStartConfirm(missing, totalRows, function()
      if ns.Synthesis:EnsurePeriods(missing, {
        onPeriodDone = function() refresh() end,
        onComplete   = function() refresh() end,
        onError      = function() refresh() end,
      }) then
        refresh()
      end
    end)
  end)

  -- Subscribe to the singleton synthesis state. UnregisterListener happens
  -- implicitly when the parent frame goes out of scope (listeners keyed
  -- by tostring(btn) so they don't collide across pages).
  if ns.Synthesis and ns.Synthesis.RegisterListener then
    ns.Synthesis:RegisterListener(tostring(btn), refresh)
  end
  btn:SetScript("OnShow", refresh)
  refresh()

  return btn
end
