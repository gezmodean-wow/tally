-- Tally — UI/AppearancePage.lua
--
-- "Appearance" tab. A thin wrapper around Cogworks' standard appearance
-- primitive (`cw:CreateAppearanceTab`, v0.14.2+ — the additive alias of the
-- older `cw:CreateUIScalingSettingsBlock`). Per the suite-wide convention
-- (cogworks#71), every cog's settings UI carries an Appearance tab whose body
-- is a single call to the shared primitive, so theme / scale / font UX
-- improvements reach every cog the day Cogworks ships them. Tally-specific
-- toggles stay on the Settings tab; Appearance is reserved for the shared
-- primitive only.
--
-- Public surface:
--   page = ns.UI.CreateAppearancePage(parent)

local addonName, ns = ...
ns.UI = ns.UI or {}

local function getCogworks()
  return LibStub and LibStub("Cogworks-1.0", true) or nil
end

local APPEARANCE_DESC =
  "UI scale and theme are shared across every Cogworks addon. Font scale and "
  .. "font family can be overridden for Tally on its own profile."

function ns.UI.CreateAppearancePage(parent)
  -- Outer wrapper returned to MainFrame, which anchors it to fill the tab
  -- body. The appearance block is parented to and anchored within `outer`.
  local outer = CreateFrame("Frame", nil, parent)

  local cw = getCogworks()
  -- v0.14.2 names the convention `CreateAppearanceTab`; v0.14.1 ships the
  -- identical primitive as `CreateUIScalingSettingsBlock`. Prefer the new
  -- name, fall back to the old so a stale vendored lib still renders the tab.
  local builder = cw and (cw.CreateAppearanceTab or cw.CreateUIScalingSettingsBlock)

  if not builder then
    local msg = outer:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    msg:SetPoint("TOPLEFT", outer, "TOPLEFT", 4, -8)
    msg:SetPoint("RIGHT", outer, "RIGHT", -4, 0)
    msg:SetJustifyH("LEFT")
    msg:SetText("Appearance settings need Cogworks-1.0 v0.14.1 or newer.")
    function outer:Refresh() end
    return outer
  end

  local block = builder(cw, outer, {
    cog         = "Tally",
    description = APPEARANCE_DESC,
  })

  -- The primitive sizes its width off parent:GetWidth() at build time — when
  -- `outer` still has no size, since MainFrame anchors the page only after
  -- create() returns. Re-anchor left+right to `outer` so the controls track
  -- the tab width and reflow on frame resize; the primitive keeps its own
  -- computed height.
  block:ClearAllPoints()
  block:SetPoint("TOPLEFT",  outer, "TOPLEFT",  0, -4)
  block:SetPoint("TOPRIGHT", outer, "TOPRIGHT", 0, -4)

  -- The block manages its own state live (every edit writes straight through
  -- Cogworks into CogworksSharedDB), so there is nothing to re-pull on tab
  -- switch — but MainFrame calls :Refresh() if present, so provide a no-op.
  function outer:Refresh() end

  return outer
end
