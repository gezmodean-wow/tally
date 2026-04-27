-- Tally — Inventory/Ownership.lua
--
-- Wraps Syndicator into a per-character + warband ownership rollup. Each
-- character contributes its bags + bank + mail; the warband is tracked
-- separately. The rollup is rebuilt lazily on demand and refreshed when
-- Syndicator broadcasts cache updates.
--
-- Rollup shape (in TallyDB.inventoryRollup):
--   characters[charKey] = { gold = N, items = { [itemKey] = { itemID, count } } }
--   warband             = { gold = N, items = { [itemKey] = { itemID, count } } }
--   lastFullScan        = epoch seconds

local addonName, ns = ...

local Ownership = {}
ns.Inventory = Ownership

-- Local item-key construction. Will be replaced once Cogworks issue #5 lands
-- and lifts ParseItemLink/MakeItemKey into the shared library; until then we
-- match FlipQueue's canonical "itemID;bonusIDs;modifiers" format on a best-
-- effort basis from Syndicator's itemLink data.
local function parseLink(itemLink)
  if not itemLink then return nil, "", "" end
  local itemString = itemLink:match("|H(item:[^|]+)|h") or itemLink:match("(item:[^|]+)")
  if not itemString then return nil, "", "" end
  local parts = { strsplit(":", itemString) }
  -- parts: { "item", id, enchant, gem1..gem4, suffix, unique, linkLevel, specID, modifiersMask, bonusCount, [bonusIDs..., modifiers...] }
  local itemID = tonumber(parts[2])
  local bonusCount = tonumber(parts[14]) or 0
  local bonusIDs = {}
  for i = 1, bonusCount do
    local v = parts[14 + i]
    if v and v ~= "" then bonusIDs[#bonusIDs + 1] = v end
  end
  table.sort(bonusIDs, function(a, b) return tonumber(a) < tonumber(b) end)
  local modifierStart = 15 + bonusCount
  local modifiers = {}
  for i = modifierStart, #parts do
    if parts[i] and parts[i] ~= "" then modifiers[#modifiers + 1] = parts[i] end
  end
  return itemID, table.concat(bonusIDs, ":"), table.concat(modifiers, ":")
end

local function makeItemKey(itemID, bonusIDs, modifiers)
  if not itemID then return nil end
  return tostring(itemID) .. ";" .. (bonusIDs or "") .. ";" .. (modifiers or "")
end

local function syndicator()
  return Syndicator and Syndicator.API or nil
end

local function foldSlots(target, slots)
  if type(slots) ~= "table" then return end
  for _, slot in ipairs(slots) do
    if type(slot) == "table" then
      if slot.bags or slot.slots then
        -- nested container shape — recurse
        foldSlots(target, slot.bags or slot.slots)
      elseif slot.itemID and slot.itemCount and slot.itemCount > 0 then
        local itemID, bonus, mods = slot.itemID, "", ""
        if slot.itemLink then
          local pid, pbonus, pmods = parseLink(slot.itemLink)
          if pid then itemID, bonus, mods = pid, pbonus, pmods end
        end
        local key = makeItemKey(itemID, bonus, mods)
        if key then
          local entry = target[key]
          if not entry then
            entry = { itemID = itemID, count = 0 }
            target[key] = entry
          end
          entry.count = entry.count + slot.itemCount
        end
      end
    end
  end
end

local function foldContainers(target, container)
  if type(container) ~= "table" then return end
  -- container is typically an array of bags; each bag is an array of slots.
  -- Some shapes are flat slot arrays. Detect by checking the first child.
  for _, group in ipairs(container) do
    if type(group) == "table" then
      if group.itemID then
        -- flat array of slots
        foldSlots(target, container)
        return
      end
      foldSlots(target, group)
    end
  end
end

local function projectCharacter(charKey)
  local api = syndicator()
  if not api or not api.GetByCharacterFullName then return nil end
  local data = api.GetByCharacterFullName(charKey)
  if type(data) ~= "table" then return nil end
  local items = {}
  foldContainers(items, data.bags)
  foldContainers(items, data.bank)
  -- Mail: bag-shaped slots; included so inflight items count toward net worth
  if type(data.mail) == "table" then foldSlots(items, data.mail) end
  return { gold = data.money or 0, items = items }
end

local function projectWarband()
  local api = syndicator()
  if not api or not api.GetWarband then return nil end
  local data = api.GetWarband(1)
  if type(data) ~= "table" then return nil end
  local items = {}
  -- Warband bank uses bankTabs in newer builds; fall back to bank otherwise.
  if type(data.bankTabs) == "table" then
    for _, tab in ipairs(data.bankTabs) do
      if type(tab) == "table" and type(tab.slots) == "table" then
        foldSlots(items, tab.slots)
      end
    end
  end
  if type(data.bank) == "table" then foldContainers(items, data.bank) end
  return { gold = data.money or 0, items = items }
end

function Ownership:Rebuild()
  local api = syndicator()
  if not api then return false, "Syndicator API unavailable" end
  local rollup = { characters = {}, warband = nil, lastFullScan = time() }

  if type(api.GetAllCharacters) == "function" then
    local chars = api.GetAllCharacters()
    if type(chars) == "table" then
      for _, charKey in ipairs(chars) do
        local proj = projectCharacter(charKey)
        if proj then rollup.characters[charKey] = proj end
      end
    end
  end

  rollup.warband = projectWarband()

  TallyDB.inventoryRollup = rollup
  ns.cw = ns.cw or ns.Cogworks
  if ns.cw and ns.cw.Fire then
    pcall(ns.cw.Fire, ns.cw, ns.cw.Events and ns.cw.Events.InventoryChanged or "InventoryChanged")
  end
  return true
end

function Ownership:Get()
  if not TallyDB.inventoryRollup or not TallyDB.inventoryRollup.lastFullScan then
    self:Rebuild()
  end
  return TallyDB.inventoryRollup
end

function Ownership:RegisterSyndicatorCallbacks()
  if not Syndicator or not Syndicator.CallbackRegistry then return end
  local owner = "Tally-Inventory"
  local registry = Syndicator.CallbackRegistry
  local function onChange()
    -- Coarse-grained refresh for now; per-character delta optimization is a
    -- follow-up once we know the cost of full rebuilds in practice.
    Ownership:Rebuild()
  end
  pcall(registry.RegisterCallback, registry, "BagCacheUpdate", onChange, owner)
  pcall(registry.RegisterCallback, registry, "WarbandBankCacheUpdate", onChange, owner)
  pcall(registry.RegisterCallback, registry, "Ready", function() Ownership:Rebuild() end, owner)
end
