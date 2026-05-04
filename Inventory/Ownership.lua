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
-- `spilledItems` is provided AND the location allows it (PERSONAL_ONLY_LOCATIONS
-- excluded), warbound items are routed to spilledItems instead of charItems.
-- spilledItems is the per-character spill bucket — projectCharacter returns
-- it separately so the warband can compose its merged view from a known
-- per-character contribution (TLY-40).
local function foldSlots(charItems, spilledItems, slots, location)
  if type(slots) ~= "table" then return end
  local allowSpill = spilledItems ~= nil and not PERSONAL_ONLY_LOCATIONS[location]
  for _, slot in ipairs(slots) do
    local link = slot and slot.itemLink
    if link and link ~= "" then
      local key = ns.Items.GetItemKey(link)
      if key then
        local itemID = ns.Items.GetNumericID(key)
        local items = charItems
        if allowSpill and isWarbound(key, link) then
          items = spilledItems
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

local function projectCharacter(charKey)
  local api = syndicator()
  if not api or not api.GetByCharacterFullName then return nil end
  local data = api.GetByCharacterFullName(charKey)
  if type(data) ~= "table" then return nil end

  local items = {}
  local spilled = {}

  -- Bags: charData.bags is keyed by bag index; index 5 is the reagent bag.
  if type(data.bags) == "table" then
    for bagIndex, slots in pairs(data.bags) do
      local loc = (bagIndex == 5) and "reagent" or "bags"
      foldSlots(items, spilled, slots, loc)
    end
  end

  -- Bank: list of tabs. Each tab may be a flat slot array OR a wrapper with
  -- `.slots`. Heuristic mirrors FlipQueue's Scanner: peek the first entry.
  if type(data.bank) == "table" then
    for _, tab in pairs(data.bank) do
      if type(tab) == "table" then
        if tab.itemLink or tab.itemCount or #tab == 0 then
          foldSlots(items, spilled, { tab }, "bank")
        else
          foldSlots(items, spilled, tab.slots or tab, "bank")
        end
      end
    end
  end

  -- Mail: bag-shaped slot array; in-flight items count toward net worth.
  if type(data.mail) == "table" then
    foldSlots(items, spilled, data.mail, "mail")
  end

  -- Equipped gear: warbound override suppressed (PERSONAL_ONLY_LOCATIONS) so
  -- a "Warbound until equipped" item that's already equipped stays with the
  -- character.
  if type(data.equipped) == "table" then
    foldSlots(items, spilled, data.equipped, "equipped")
  end

  -- Void storage: bound transmog stash, character-only by mechanic.
  if type(data.void) == "table" then
    foldSlots(items, spilled, data.void, "void")
  end

  -- Active AH auctions: bound items can't be listed, so the warbound route
  -- never fires here in practice. Saleable is forced true by isSlotSaleable.
  if type(data.auctions) == "table" then
    foldSlots(items, spilled, data.auctions, "auctions")
  end

  return { gold = data.money or 0, items = items, spilled = spilled }
end

local function projectWarbandBank()
  local api = syndicator()
  if not api or not api.GetWarband then return nil end
  local data = api.GetWarband(1)
  if type(data) ~= "table" then return nil end

  local bankItems = {}

  -- warbandData.bank is a list of tabs; each tab is { slots, name, ... } or
  -- a flat slot array directly. Same pattern as character bank.
  if type(data.bank) == "table" then
    for _, tab in pairs(data.bank) do
      if type(tab) == "table" then
        local slots = tab.slots or tab
        foldSlots(bankItems, nil, slots, "warbank")
      end
    end
  end

  return { gold = data.money or 0, bankItems = bankItems }
end

-- Rebuild warband.items as the merge of warband.bankItems plus every
-- character's warbound spill in warband.spillsByChar. This is the public
-- field every consumer reads (Inventory page, NetWorth, Research, etc.) —
-- the per-source split is internal bookkeeping. Called whenever any input
-- changes (Rebuild / RefreshCharacter / RefreshWarband). TLY-40.
local function recomputeWarbandItems(warband)
  local merged = {}

  local function fold(src)
    if type(src) ~= "table" then return end
    for key, e in pairs(src) do
      local m = merged[key]
      if not m then
        m = { itemID = e.itemID, total = 0, saleable = 0, locations = {} }
        merged[key] = m
      end
      m.total = m.total + (e.total or 0)
      m.saleable = m.saleable + (e.saleable or 0)
      if e.locations then
        for loc, count in pairs(e.locations) do
          m.locations[loc] = (m.locations[loc] or 0) + count
        end
      end
    end
  end

  fold(warband.bankItems)
  for _, charSpills in pairs(warband.spillsByChar or {}) do
    fold(charSpills)
  end

  warband.items = merged
end

function Ownership:Rebuild()
  local api = syndicator()
  if not api then return false, "Syndicator API unavailable" end

  -- Project the warband bank first; characters contribute their warbound
  -- spills into a per-character map (warband.spillsByChar[charKey]) which
  -- we merge into warband.items at the end via recomputeWarbandItems.
  local bank = projectWarbandBank() or { gold = 0, bankItems = {} }

  local rollup = {
    characters = {},
    warband = {
      gold = bank.gold,
      bankItems = bank.bankItems,
      spillsByChar = {},
      items = {},
    },
    lastFullScan = time(),
  }

  if type(api.GetAllCharacters) == "function" then
    local chars = api.GetAllCharacters()
    if type(chars) == "table" then
      for _, charKey in ipairs(chars) do
        local proj = projectCharacter(charKey)
        if proj then
          rollup.characters[charKey] = { gold = proj.gold, items = proj.items }
          rollup.warband.spillsByChar[charKey] = proj.spilled
        end
      end
    end
  end

  recomputeWarbandItems(rollup.warband)

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
-- TLY-40: per-character warband spills are tracked in
-- warband.spillsByChar[charKey] and replaced wholesale on each refresh, so
-- repeated BagCacheUpdate / AuctionsCacheUpdate fires no longer compound
-- the warband totals (the alpha8 dup bug). The merged warband.items view is
-- recomputed from bankItems + spillsByChar[*] after the swap.
function Ownership:RefreshCharacter(charKey)
  local rollup = TallyDB.inventoryRollup
  if not rollup or not rollup.warband or not rollup.warband.bankItems then
    return self:Rebuild()
  end
  local proj = projectCharacter(charKey)
  if proj then
    rollup.characters[charKey] = { gold = proj.gold, items = proj.items }
    rollup.warband.spillsByChar = rollup.warband.spillsByChar or {}
    rollup.warband.spillsByChar[charKey] = proj.spilled
    recomputeWarbandItems(rollup.warband)
    rollup.lastFullScan = time()
  end
  if ns.cw and ns.cw.Fire then
    pcall(ns.cw.Fire, ns.cw, ns.cw.Events and ns.cw.Events.InventoryChanged or "InventoryChanged")
  end
  return true
end

-- Refresh just the warband bank. Character spills are untouched — they
-- live under warband.spillsByChar and only that character's RefreshCharacter
-- updates them. recomputeWarbandItems re-merges the new bankItems with the
-- existing spills.
function Ownership:RefreshWarband()
  local rollup = TallyDB.inventoryRollup
  if not rollup or not rollup.warband or not rollup.warband.bankItems then
    return self:Rebuild()
  end
  local bank = projectWarbandBank() or { gold = 0, bankItems = {} }
  rollup.warband.gold = bank.gold
  rollup.warband.bankItems = bank.bankItems
  recomputeWarbandItems(rollup.warband)
  rollup.lastFullScan = time()
  if ns.cw and ns.cw.Fire then
    pcall(ns.cw.Fire, ns.cw, ns.cw.Events and ns.cw.Events.InventoryChanged or "InventoryChanged")
  end
  return true
end

function Ownership:Get()
  local rollup = TallyDB.inventoryRollup
  if not rollup or not rollup.lastFullScan then
    self:Rebuild()
  -- Migration: pre-TLY-40 rollups stored only warband.items (no bankItems
  -- or spillsByChar). The existing items map may be inflated by the
  -- duplication bug, so force a full rebuild on first read after upgrade.
  elseif not rollup.warband or not rollup.warband.bankItems then
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
