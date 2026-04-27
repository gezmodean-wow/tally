-- Tally — Util/Items.lua
--
-- Item-key parsing and canonicalization. Lifted verbatim from FlipQueue's
-- Core.lua (lines ~115–223) so Tally's rollup and research lookups produce
-- identical keys to FlipQueue. Delete this file and switch to Cogworks's
-- versions once cogworks issue #6 lands.

local addonName, ns = ...

local Items = {}
ns.Items = Items

-- Matches FlippingPal's GetItemKey format: "itemID;bonusIDs;modifiers"
function Items.MakeItemKey(itemID, bonusIDs, modifiers)
  return string.format("%s;%s;%s", tostring(itemID), bonusIDs or "", modifiers or "")
end

-- Parse item link to extract (itemID, bonusIDs, modifiers).
-- Handles battle pets (|Hbattlepet:speciesID:level:quality:...) and standard
-- items. Battle-pet keys are namespaced "pet:<speciesID>".
function Items.ParseItemLink(itemLink)
  if not itemLink then return nil end

  local speciesID = itemLink:match("|Hbattlepet:(%d+)")
  if speciesID then
    local petQuality = itemLink:match("|Hbattlepet:%d+:%d+:(%d+)")
    return "pet:" .. speciesID, "q" .. (petQuality or "0"), ""
  end

  local itemString = itemLink:match("item[%-?%d:]+")
  if not itemString then return nil end

  local parts = { strsplit(":", itemString) }
  local itemID = parts[2]
  if not itemID or itemID == "" then return nil end

  local bonusIDs, modifiers = "", ""
  if #parts >= 14 then
    local numBonusIDs = tonumber(parts[14]) or 0
    local bonusList = {}
    for i = 1, numBonusIDs do
      local bid = parts[14 + i]
      if bid and bid ~= "" then bonusList[#bonusList + 1] = bid end
    end
    bonusIDs = table.concat(bonusList, ":")

    local modStart = 14 + numBonusIDs + 1
    if #parts >= modStart then
      local numMods = tonumber(parts[modStart]) or 0
      local modList = {}
      for i = 1, numMods do
        local mType = parts[modStart + (i * 2) - 1]
        local mVal  = parts[modStart + (i * 2)]
        -- FlipQueue keeps only modifier type 9 (crafted-ilvl tier); other
        -- modifiers are dropped to keep keys stable across cosmetic variations.
        if mType and mVal and mType ~= "" and mVal ~= "" and mType == "9" then
          modList[#modList + 1] = mType .. "=" .. mVal
        end
      end
      modifiers = table.concat(modList, ":")
    end
  end

  return itemID, bonusIDs, modifiers
end

-- Cached link → canonical-key conversion. Bounded so a long session doesn't
-- accumulate stale entries.
local cache = {}
local cacheSize = 0
local MAX_CACHE = 1000

function Items.GetItemKey(itemLink)
  if not itemLink or itemLink == "" then return nil end
  local cached = cache[itemLink]
  if cached then return cached end

  local itemID, bonusIDs, modifiers = Items.ParseItemLink(itemLink)
  if not itemID then return nil end
  local key = Items.MakeItemKey(itemID, bonusIDs, modifiers)
  cache[itemLink] = key
  cacheSize = cacheSize + 1
  if cacheSize > MAX_CACHE then
    wipe(cache)
    cacheSize = 0
  end
  return key
end

-- Extract the numeric WoW item ID from a canonical key. Returns nil for pets.
function Items.GetNumericID(itemKey)
  if not itemKey or itemKey == "" then return nil end
  if itemKey:find("^pet:") then return nil end
  local idStr = itemKey:match("^(%d+);")
  return idStr and tonumber(idStr) or nil
end

function Items.IsPetKey(itemKey)
  return type(itemKey) == "string" and itemKey:find("^pet:") ~= nil
end
