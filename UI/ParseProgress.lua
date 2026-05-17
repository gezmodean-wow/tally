-- Tally — UI/ParseProgress.lua
--
-- Loading bar for the data-spine session parse (TLY-79).
--
-- The spine parses sibling saved-variables on demand; a big TSM CSV is a
-- 2-3s blocking pass. Tester feedback (toeknee, #76 Q8) is explicit: that
-- pause is acceptable *only if a loading bar shows*, so the player knows
-- the game is working, not frozen.
--
-- This module is a thin listener on ns.Spine.ParseCache. It owns no parse
-- logic — it just renders the ParseCache state as a progress bar built on
-- ns.UI.CreateProgressBar. The bar advances one notch per source (the
-- parse steps source-by-source); within a single source's blocking parse
-- the frame cannot animate anyway, so the label — "Parsing TSM
-- Accounting… (2 of 3)" — is what tells the player which source is
-- churning. The bar registers its listener at load; it shows itself the
-- moment a parse starts and fades shortly after it completes.

local addonName, ns = ...
ns.UI = ns.UI or {}

-- Friendly source labels for the bar. ParseCache enumerates Ledger source
-- record names; map them to what a player recognizes.
local SOURCE_LABELS = {
  tsm         = "TSM Accounting",
  flipqueue   = "FlipQueue",
  journalator = "Journalator",
  native      = "Tally capture",
}

local function sourceLabel(name)
  return SOURCE_LABELS[name] or name or "sibling data"
end

local bar
local progressText = "Parsing sibling data…"

local function ensureBar()
  if bar then return bar end
  if not ns.UI.CreateProgressBar then return nil end
  bar = ns.UI.CreateProgressBar({
    label    = "Tally",
    total    = 1,
    -- formatFn owns the label entirely so SetTotal/SetValue refreshes
    -- pull our text rather than the widget's default "x / y (%)".
    formatFn = function() return progressText end,
  })
  return bar
end

-- Render one ParseCache state update.
local function onUpdate(state)
  if type(state) ~= "table" then return end

  if state.phase == "parsing" then
    local b = ensureBar()
    if not b then return end
    local total = state.total or 0
    local done  = state.done or 0
    if state.currentSource then
      progressText = string.format("Parsing %s…", sourceLabel(state.currentSource))
    else
      progressText = "Parsing sibling data…"
    end
    if total > 0 then
      progressText = string.format("%s  (%d of %d)",
        progressText, math.min(done + 1, total), total)
      b:SetTotal(total)
      b:SetValue(done)
    end
    b:Show()

  elseif state.phase == "ready" then
    if bar then
      -- Complete() flashes a done label and fades the frame after ~2s.
      bar:Complete("Tally — sibling data ready.")
    end

  elseif state.phase == "error" then
    if bar then
      bar:Complete("Tally — parse error. See /tally spine.")
    end
  end
end

-- Register against the parse cache at load. RegisterListener only stores
-- the callback; no frame is created until the first "parsing" update,
-- which can only fire after login — so this is zero login cost.
if ns.Spine and ns.Spine.ParseCache and ns.Spine.ParseCache.RegisterListener then
  ns.Spine.ParseCache:RegisterListener("parse-progress", onUpdate)
end
