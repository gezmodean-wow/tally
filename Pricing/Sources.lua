-- Tally — Pricing/Sources.lua
--
-- Adapter over TSM for price lookups, plus WoW Token special-case. Strategy is
-- a TSM price expression string ("DBRegionMarketAvg" by default; any TSM-valid
-- custom expression works). When TSM is absent or returns nil, falls back to
-- vendor sell price via GetItemInfo.

local addonName, ns = ...

local Pricing = {}
ns.Pricing = Pricing

local WOW_TOKEN_ITEM_ID = 122270
local TOKEN_REFRESH_SECONDS = 1800 -- 30 minutes; the API is rate-limited

local tokenCache = { price = nil, fetchedAt = 0 }
local tsmAvailableWarned = false

local function tsmAvailable()
  return type(TSM_API) == "table" and type(TSM_API.GetCustomPriceValue) == "function"
end

-- Validate a price expression. If TSM is absent we accept anything — it'll
-- silently fall through to the vendor-price floor at lookup time.
function Pricing:IsValidStrategy(expression)
  if not expression or expression == "" then return false end
  if not tsmAvailable() then return true end
  if type(TSM_API.IsCustomPriceValid) ~= "function" then return true end
  local ok, valid = pcall(TSM_API.IsCustomPriceValid, expression)
  return ok and valid
end

local function getItemString(itemID, itemKey)
  if not itemID then return nil end
  if tsmAvailable() and type(TSM_API.ToItemString) == "function" then
    local wowStr = "i:" .. itemID
    local ok, result = pcall(TSM_API.ToItemString, wowStr)
    if ok and result then return result end
  end
  return "i:" .. itemID
end

local function getVendorPrice(itemID)
  if not itemID then return 0 end
  local _, _, _, _, _, _, _, _, _, _, sellPrice = GetItemInfo(itemID)
  return sellPrice or 0
end

local function getTokenPrice()
  local now = GetTime and GetTime() or 0
  if tokenCache.price and (now - tokenCache.fetchedAt) < TOKEN_REFRESH_SECONDS then
    return tokenCache.price
  end
  if C_WowTokenPublic and C_WowTokenPublic.GetCurrentMarketPrice then
    -- UpdateMarketPrice is the kick; GetCurrentMarketPrice reads the cached value.
    if C_WowTokenPublic.UpdateMarketPrice then pcall(C_WowTokenPublic.UpdateMarketPrice) end
    local price = C_WowTokenPublic.GetCurrentMarketPrice()
    if price and price > 0 then
      tokenCache.price = price
      tokenCache.fetchedAt = now
      return price
    end
  end
  return tokenCache.price -- may be nil; caller falls back to vendor (~0 for tokens)
end

-- Look up a per-unit copper value for an item under the given strategy.
-- Returns (copper, source) where source is one of "tsm", "token", "vendor", "none".
function Pricing:GetUnitValue(itemID, itemKey, strategy)
  if itemID == WOW_TOKEN_ITEM_ID then
    local p = getTokenPrice()
    if p then return p, "token" end
  end

  if tsmAvailable() and strategy then
    local itemString = getItemString(itemID, itemKey)
    if itemString then
      local ok, copper = pcall(TSM_API.GetCustomPriceValue, strategy, itemString)
      if ok and copper and copper > 0 then
        return copper, "tsm"
      end
    end
  elseif not tsmAvailableWarned then
    tsmAvailableWarned = true
    print("|cff7fbfffTally:|r TSM not detected — net-worth values fall back to vendor prices.")
  end

  local vendor = getVendorPrice(itemID)
  if vendor > 0 then return vendor, "vendor" end
  return 0, "none"
end

-- Aggregate value: itemMap is { [itemKey] = { itemID, total, saleable } }.
-- `countField` selects which count to value — defaults to "saleable" so net
-- worth excludes bound items. Pass `countField = "total"` for owned-worth.
-- Returns (totalCopper, breakdown) where breakdown[source] = copper subtotal.
function Pricing:ValueItemMap(itemMap, strategy, opts)
  local field = (opts and opts.countField) or "saleable"
  local total = 0
  local breakdown = { tsm = 0, token = 0, vendor = 0, none = 0 }
  for itemKey, entry in pairs(itemMap) do
    local count = entry[field] or 0
    if count > 0 then
      local unit, source = self:GetUnitValue(entry.itemID, itemKey, strategy)
      local subtotal = unit * count
      total = total + subtotal
      breakdown[source] = (breakdown[source] or 0) + subtotal
    end
  end
  return total, breakdown
end

function Pricing:HasTSM()
  return tsmAvailable()
end
