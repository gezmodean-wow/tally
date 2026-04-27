-- Tally — Inventory/Ownership.lua
--
-- Wraps Syndicator into a per-character + warband ownership rollup. Each
-- character contributes its bags + reagent + bank; the warband bank is
-- tracked separately. Refreshed lazily and on Syndicator cache updates.
--
-- Walker pattern lifted from FlipQueue's Scanner.lua to match Syndicator's
-- actual data shapes (which differ between bags, bank tabs, and warband).
--
-- Rollup shape (in TallyDB.inventoryRollup):
--   characters[charKey] = { gold, items = { [itemKey] = { itemID, total, saleable, locations } } }
--   warband             = { gold, items = { [itemKey] = { itemID, total, saleable } } }
--   lastFullScan        = epoch seconds
--
-- `total` is every instance owned. `saleable` is the subset that isn't bound
-- (Syndicator's per-slot isBound flag is false). Net worth uses `saleable`;
-- a future "owned worth" view uses `total`.

local addonName, ns = ...

local Ownership = {}
ns.Inventory = Ownership

local WOW_TOKEN_ITEM_ID = 122270

local function syndicator()
  return Syndicator and Syndicator.API or nil
end

-- WoW Tokens are technically bind-on-pickup but are convertible to gold or
-- game time, so we count them as saleable regardless of isBound.
local function isSlotSaleable(slot, itemID)
  if itemID == WOW_TOKEN_ITEM_ID then return true end
  return not slot.isBound
end

-- Fold a Syndicator slot list into the caller's items table. Each slot
-- carries the full hyperlink (preserves bonus IDs / modifiers), so we feed
-- it through the canonical key helper rather than reading itemID directly.
local function foldSlots(items, slots, location)
  if type(slots) ~= "table" then return end
  for _, slot in ipairs(slots) do
    local link = slot and slot.itemLink
    if link and link ~= "" then
      local key = ns.Items.GetItemKey(link)
      if key then
        local entry = items[key]
        if not entry then
          local itemID = ns.Items.GetNumericID(key)
          entry = { itemID = itemID, total = 0, saleable = 0, locations = {} }
          items[key] = entry
        end
        local count = slot.itemCount or 1
        entry.total = entry.total + count
        if isSlotSaleable(slot, entry.itemID) then
          entry.saleable = entry.saleable + count
        end
        if location then
          entry.locations[location] = (entry.locations[location] or 0) + count
        end
      end
    end
  end
end

local function projectCharacter(charKey)
  local api = syndicator()
  if not api or not api.GetByCharacterFullName then return nil end
  local data = api.GetByCharacterFullName(charKey)
  if type(data) ~= "table" then return nil end

  local items = {}

  -- Bags: charData.bags is keyed by bag index; index 5 is the reagent bag.
  if type(data.bags) == "table" then
    for bagIndex, slots in pairs(data.bags) do
      local loc = (bagIndex == 5) and "reagent" or "bags"
      foldSlots(items, slots, loc)
    end
  end

  -- Bank: list of tabs. Each tab may be a flat slot array OR a wrapper with
  -- `.slots`. Heuristic mirrors FlipQueue's Scanner: peek the first entry.
  if type(data.bank) == "table" then
    for _, tab in pairs(data.bank) do
      if type(tab) == "table" then
        if tab.itemLink or tab.itemCount or #tab == 0 then
          foldSlots(items, { tab }, "bank")
        else
          foldSlots(items, tab.slots or tab, "bank")
        end
      end
    end
  end

  -- Mail: bag-shaped slot array; in-flight items count toward net worth.
  if type(data.mail) == "table" then
    foldSlots(items, data.mail, "mail")
  end

  return { gold = data.money or 0, items = items }
end

local function projectWarband()
  local api = syndicator()
  if not api or not api.GetWarband then return nil end
  local data = api.GetWarband(1)
  if type(data) ~= "table" then return nil end

  local items = {}

  -- warbandData.bank is a list of tabs; each tab is { slots, name, ... } or
  -- a flat slot array directly. Same pattern as character bank.
  if type(data.bank) == "table" then
    for _, tab in pairs(data.bank) do
      if type(tab) == "table" then
        local slots = tab.slots or tab
        foldSlots(items, slots, "warbank")
      end
    end
  end

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
    Ownership:Rebuild()
  end
  pcall(registry.RegisterCallback, registry, "BagCacheUpdate", onChange, owner)
  pcall(registry.RegisterCallback, registry, "WarbandBankCacheUpdate", onChange, owner)
  pcall(registry.RegisterCallback, registry, "Ready", function() Ownership:Rebuild() end, owner)
end

-- Aggregate a single itemKey across the entire rollup.
-- Returns (totalCount, perCharacterTable) where perCharacterTable is
-- { [charKey] = count } including a synthetic "Warband" entry.
-- Aggregate a single itemKey across the rollup.
-- Returns ({ total, saleable }, perChar) where perChar[charKey] = { total, saleable }.
function Ownership:GetItemOwnership(itemKey)
  local rollup = self:Get() or {}
  local agg = { total = 0, saleable = 0 }
  local byKey = {}
  for charKey, char in pairs(rollup.characters or {}) do
    local entry = char.items and char.items[itemKey]
    if entry and entry.total > 0 then
      byKey[charKey] = { total = entry.total, saleable = entry.saleable or 0 }
      agg.total = agg.total + entry.total
      agg.saleable = agg.saleable + (entry.saleable or 0)
    end
  end
  if rollup.warband then
    local entry = rollup.warband.items and rollup.warband.items[itemKey]
    if entry and entry.total > 0 then
      byKey["Warband"] = { total = entry.total, saleable = entry.saleable or 0 }
      agg.total = agg.total + entry.total
      agg.saleable = agg.saleable + (entry.saleable or 0)
    end
  end
  return agg, byKey
end

-- Aggregate ownership for all keys sharing a numeric itemID. Useful when the
-- user passes a bare item ID and we want to roll up across bonus-ID variants.
function Ownership:GetItemOwnershipByID(itemID)
  if not itemID then return { total = 0, saleable = 0 }, {}, {} end
  local rollup = self:Get() or {}
  local agg = { total = 0, saleable = 0 }
  local byKey = {}
  local matchedKeys = {}
  local function fold(charKey, items)
    if type(items) ~= "table" then return end
    for key, entry in pairs(items) do
      local id = ns.Items.GetNumericID(key)
      if id == itemID and entry.total > 0 then
        byKey[charKey] = byKey[charKey] or { total = 0, saleable = 0 }
        byKey[charKey].total = byKey[charKey].total + entry.total
        byKey[charKey].saleable = byKey[charKey].saleable + (entry.saleable or 0)
        matchedKeys[key] = true
        agg.total = agg.total + entry.total
        agg.saleable = agg.saleable + (entry.saleable or 0)
      end
    end
  end
  for charKey, char in pairs(rollup.characters or {}) do
    fold(charKey, char.items)
  end
  if rollup.warband then fold("Warband", rollup.warband.items) end
  return agg, byKey, matchedKeys
end
