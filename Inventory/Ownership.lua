-- Tally — Inventory/Ownership.lua
--
-- Wraps Syndicator into a per-character + warband ownership rollup. Each
-- character contributes bags + reagent + bank + mail + equipped + void +
-- active auctions; the warband bank is tracked separately. Refreshed
-- lazily and on Syndicator cache updates.
--
-- Walker pattern lifted from FlipQueue's Scanner.lua to match Syndicator's
-- actual data shapes (which differ between bags, bank tabs, and warband).
--
-- Ownership model (TLY-16):
--   - Personal: items physically on the character (bags, personal bank, mail,
--     equipped, void) AND personally bound (or unbound).
--   - Warband: warbank tab contents, plus warbound items wherever they sit
--     — a warbound item in a character's bags belongs to the warband, not
--     that character.
--
-- Rollup shape (in TallyDB.inventoryRollup):
--   characters[charKey] = { gold, items = { [itemKey] = { itemID, total, saleable, locations } } }
--   warband             = { gold, items = { [itemKey] = { itemID, total, saleable, locations } } }
--   lastFullScan        = epoch seconds
--
-- `total` is every instance owned. `saleable` is the subset that isn't bound
-- (Syndicator's per-slot isBound flag is false). Net worth uses `saleable`;
-- the owned-worth view uses `total`.

local addonName, ns = ...

local Ownership = {}
ns.Inventory = Ownership

local WOW_TOKEN_ITEM_ID = 122270

-- Bind types reported by GetItemInfo (14th return) that mean "warbound" —
-- the item travels with the warband, not a single character.
--   7 = LE_ITEM_BIND_TO_BNET_ACCOUNT          ("Bound to Account")
--   8 = LE_ITEM_BIND_TO_WOW_ACCOUNT           ("Bound to Warband")
--   9 = LE_ITEM_BIND_TO_BNET_ACCOUNT_UNTIL_EQUIPPED ("Warbound until equipped")
-- Cross-checked against FlipQueue's Tracker.lua + Export.lua, which classify
-- these three identically.
local WARBOUND_BIND_TYPES = { [7] = true, [8] = true, [9] = true }

-- Locations where the item is physically attached to the character and the
-- warbound override is suppressed:
--   - equipped: a "warbound until equipped" item, once equipped, soulbinds
--     to the character. We can't see that state-change from cache, but if
--     it's equipped we know it's effectively character-bound.
--   - void: void storage is character-only by mechanic.
local PERSONAL_ONLY_LOCATIONS = { equipped = true, void = true }

local function syndicator()
  return Syndicator and Syndicator.API or nil
end

-- WoW Tokens are technically bind-on-pickup but are convertible to gold or
-- game time, so we count them as saleable regardless of isBound. Items
-- currently listed on the AH are saleable by definition — they're literally
-- being sold — even though Syndicator may report them with isBound.
local function isSlotSaleable(slot, itemID, location)
  if location == "auctions" then return true end
  if itemID == WOW_TOKEN_ITEM_ID then return true end
  return not slot.isBound
end

-- Cached bind classification keyed by canonical itemKey. Bind type is a
-- property of the item template, not the slot, so once we resolve it we can
-- reuse it across every slot holding that item. Negative results are not
-- cached so a transient GetItemInfo miss retries on the next scan.
local bindClassCache = {}

local function isWarbound(itemKey, itemLink)
  local cached = bindClassCache[itemKey]
  if cached ~= nil then return cached end
  local bindType = select(14, GetItemInfo(itemLink))
  if bindType == nil then return false end
  local result = WARBOUND_BIND_TYPES[bindType] == true
  bindClassCache[itemKey] = result
  return result
end

-- Fold a Syndicator slot list into the destination items table(s). When
-- `warbandItems` is provided AND the location allows it (PERSONAL_ONLY_LOCATIONS
-- excluded), warbound items are routed to warbandItems instead of charItems.
-- Each slot carries the full hyperlink (preserves bonus IDs / modifiers), so
-- we feed it through the canonical key helper rather than reading itemID
-- directly.
local function foldSlots(charItems, warbandItems, slots, location)
  if type(slots) ~= "table" then return end
  local allowWarboundRoute = warbandItems ~= nil and not PERSONAL_ONLY_LOCATIONS[location]
  for _, slot in ipairs(slots) do
    local link = slot and slot.itemLink
    if link and link ~= "" then
      local key = ns.Items.GetItemKey(link)
      if key then
        local itemID = ns.Items.GetNumericID(key)
        local items = charItems
        if allowWarboundRoute and isWarbound(key, link) then
          items = warbandItems
        end
        local entry = items[key]
        if not entry then
          entry = { itemID = itemID, total = 0, saleable = 0, locations = {} }
          items[key] = entry
        end
        local count = slot.itemCount or 1
        entry.total = entry.total + count
        if isSlotSaleable(slot, entry.itemID, location) then
          entry.saleable = entry.saleable + count
        end
        if location then
          entry.locations[location] = (entry.locations[location] or 0) + count
        end
      end
    end
  end
end

local function projectCharacter(charKey, warbandItems)
  local api = syndicator()
  if not api or not api.GetByCharacterFullName then return nil end
  local data = api.GetByCharacterFullName(charKey)
  if type(data) ~= "table" then return nil end

  local items = {}

  -- Bags: charData.bags is keyed by bag index; index 5 is the reagent bag.
  if type(data.bags) == "table" then
    for bagIndex, slots in pairs(data.bags) do
      local loc = (bagIndex == 5) and "reagent" or "bags"
      foldSlots(items, warbandItems, slots, loc)
    end
  end

  -- Bank: list of tabs. Each tab may be a flat slot array OR a wrapper with
  -- `.slots`. Heuristic mirrors FlipQueue's Scanner: peek the first entry.
  if type(data.bank) == "table" then
    for _, tab in pairs(data.bank) do
      if type(tab) == "table" then
        if tab.itemLink or tab.itemCount or #tab == 0 then
          foldSlots(items, warbandItems, { tab }, "bank")
        else
          foldSlots(items, warbandItems, tab.slots or tab, "bank")
        end
      end
    end
  end

  -- Mail: bag-shaped slot array; in-flight items count toward net worth.
  if type(data.mail) == "table" then
    foldSlots(items, warbandItems, data.mail, "mail")
  end

  -- Equipped gear: warbound override suppressed (PERSONAL_ONLY_LOCATIONS) so
  -- a "Warbound until equipped" item that's already equipped stays with the
  -- character.
  if type(data.equipped) == "table" then
    foldSlots(items, warbandItems, data.equipped, "equipped")
  end

  -- Void storage: bound transmog stash, character-only by mechanic.
  if type(data.void) == "table" then
    foldSlots(items, warbandItems, data.void, "void")
  end

  -- Active AH auctions: bound items can't be listed, so the warbound route
  -- never fires here in practice. Saleable is forced true by isSlotSaleable.
  if type(data.auctions) == "table" then
    foldSlots(items, warbandItems, data.auctions, "auctions")
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
        foldSlots(items, nil, slots, "warbank")
      end
    end
  end

  return { gold = data.money or 0, items = items }
end

function Ownership:Rebuild()
  local api = syndicator()
  if not api then return false, "Syndicator API unavailable" end

  -- Project the warband first so character scans can spill warbound items
  -- into rollup.warband.items as they walk each character. If Syndicator
  -- doesn't expose a warband (no warband at all), still create an empty
  -- bucket — warbound items are still warbound regardless of warbank state.
  local warband = projectWarband() or { gold = 0, items = {} }

  local rollup = {
    characters = {},
    warband = warband,
    lastFullScan = time(),
  }

  if type(api.GetAllCharacters) == "function" then
    local chars = api.GetAllCharacters()
    if type(chars) == "table" then
      for _, charKey in ipairs(chars) do
        local proj = projectCharacter(charKey, warband.items)
        if proj then rollup.characters[charKey] = proj end
      end
    end
  end

  TallyDB.inventoryRollup = rollup
  if ns.cw and ns.cw.Fire then
    pcall(ns.cw.Fire, ns.cw, ns.cw.Events and ns.cw.Events.InventoryChanged or "InventoryChanged")
  end
  return true
end

-- Refresh just one character's items in the existing rollup, leaving the
-- other characters and warband untouched. Drastically cheaper than the full
-- :Rebuild for the common case "user moved an item between bags" — no need
-- to re-walk every char on the account.
--
-- TLY-21: warbound items routed via projectCharacter still spill into
-- rollup.warband.items. That spill is one-way: refreshing one character
-- can ADD warbound items to the warband bucket, but it can't REMOVE
-- warbound items deposited by *other* characters. For the bag-slot-change
-- case that's a no-op (the moved item is still in someone's bags); for
-- the cross-character-trade case the next full :Rebuild settles it.
function Ownership:RefreshCharacter(charKey)
  if not TallyDB.inventoryRollup or not TallyDB.inventoryRollup.warband then
    return self:Rebuild()
  end
  local proj = projectCharacter(charKey, TallyDB.inventoryRollup.warband.items)
  if proj then
    TallyDB.inventoryRollup.characters[charKey] = proj
    TallyDB.inventoryRollup.lastFullScan = time()
  end
  if ns.cw and ns.cw.Fire then
    pcall(ns.cw.Fire, ns.cw, ns.cw.Events and ns.cw.Events.InventoryChanged or "InventoryChanged")
  end
  return true
end

-- Refresh just the warband bucket. Used when WarbandBankCacheUpdate fires.
function Ownership:RefreshWarband()
  if not TallyDB.inventoryRollup then return self:Rebuild() end
  local warband = projectWarband() or { gold = 0, items = {} }
  TallyDB.inventoryRollup.warband = warband
  TallyDB.inventoryRollup.lastFullScan = time()
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

-- Coalesce rapid Syndicator events behind a debounce timer so a single
-- looting interaction doesn't drive 5+ rebuilds in quick succession.
local DEBOUNCE_SEC = 0.5
local pendingFull          -- a Ready fired; do a full rebuild
local pendingWarband       -- WarbandBankCacheUpdate fired
local pendingCharSet       -- { [charKey] = true } from BagCacheUpdate / AuctionsCacheUpdate
local pendingTimer

local function flushPending()
  pendingTimer = nil
  if pendingFull then
    Ownership:Rebuild()
  else
    if pendingWarband then Ownership:RefreshWarband() end
    if pendingCharSet then
      for charKey in pairs(pendingCharSet) do
        Ownership:RefreshCharacter(charKey)
      end
    end
  end
  pendingFull, pendingWarband, pendingCharSet = false, false, nil
end

local function arm()
  if pendingTimer then return end
  if C_Timer and C_Timer.After then
    pendingTimer = true
    C_Timer.After(DEBOUNCE_SEC, flushPending)
  else
    flushPending()
  end
end

local function scheduleFull()
  pendingFull = true
  arm()
end

local function scheduleWarband()
  pendingWarband = true
  arm()
end

local function scheduleCharacter(charKey)
  if not charKey or charKey == "" then return end
  pendingCharSet = pendingCharSet or {}
  pendingCharSet[charKey] = true
  arm()
end

function Ownership:RegisterSyndicatorCallbacks()
  if not Syndicator or not Syndicator.CallbackRegistry then return end
  local owner = "Tally-Inventory"
  local registry = Syndicator.CallbackRegistry
  -- Syndicator's BagCacheUpdate / AuctionsCacheUpdate pass the affected
  -- character's full key as the first arg. Capture it so we only rebuild
  -- that character's bucket — re-walking every saved character on every
  -- bag-slot change was the dominant CPU cost pre-TLY-21.
  pcall(registry.RegisterCallback, registry, "BagCacheUpdate",
    function(_, charKey) scheduleCharacter(charKey) end, owner)
  pcall(registry.RegisterCallback, registry, "AuctionsCacheUpdate",
    function(_, charKey) scheduleCharacter(charKey) end, owner)
  pcall(registry.RegisterCallback, registry, "WarbandBankCacheUpdate",
    function() scheduleWarband() end, owner)
  -- Ready fires once when Syndicator finishes loading its initial cache.
  -- Full rebuild on Ready primes the rollup with every saved character.
  pcall(registry.RegisterCallback, registry, "Ready",
    function() scheduleFull() end, owner)
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
