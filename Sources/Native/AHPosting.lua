-- Tally — Sources/Native/AHPosting.lua
--
-- Native capture bucket: auction-house posting + cancel events.
--
-- TLY-31 Phase A scope: hook `C_AuctionHouse.PostItem` and `PostCommodity`
-- to emit `ah-deposit` rows the instant the player posts; hook
-- `C_AuctionHouse.CancelAuction` to emit `ah-cancel` rows. Together with
-- AHInvoice's mail-side capture, Tally now has end-to-end ownership of the
-- AH lifecycle without any sibling-addon dependency.
--
-- Deposit copper is computed from `CalculateItemDeposit` /
-- `CalculateCommodityDeposit`. Sign on `ah-deposit` is 0 (Ledger:KindSign);
-- Lifecycle pairs the deposit with the eventual sale / expire / cancel at
-- view time so deposit-forfeit math falls out without double-counting.
--
-- Known edge case: if the post fails server-side after the hook fires (rare
-- — usually the client validates first), the row is orphan. Acceptable for
-- V1; future refinement could gate emission on AUCTION_HOUSE_AUCTION_CREATED
-- and match against a transient post-cache.
--
-- Cancel needs the auctionID-to-item mapping; we maintain a cache refreshed
-- on `OWNED_AUCTIONS_UPDATED` because Blizzard's local table may have
-- evicted the row by the time the hook resolves the lookup.

local addonName, ns = ...

local Native = ns.Sources and ns.Sources.Native
if not Native then return end

local SOURCE_NAME = Native.SOURCE_NAME

-- Skip-counter slots
Native.skipCounters.posting_no_item     = 0
Native.skipCounters.posting_no_deposit  = 0
Native.skipCounters.posting_setup_gate  = 0
Native.skipCounters.cancel_no_auction   = 0
Native.skipCounters.cancel_setup_gate   = 0

-- ============================================================================
-- Owned-auction cache
-- ============================================================================

local auctionCache = {}

local function refreshOwnedAuctionCache()
  if not (C_AuctionHouse and C_AuctionHouse.GetOwnedAuctions) then return end
  local ok, list = pcall(C_AuctionHouse.GetOwnedAuctions)
  if not ok or type(list) ~= "table" then return end
  wipe(auctionCache)
  for _, info in ipairs(list) do
    if info.auctionID then auctionCache[info.auctionID] = info end
  end
end

local cacheFrame = CreateFrame("Frame")
cacheFrame:RegisterEvent("OWNED_AUCTIONS_UPDATED")
cacheFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
cacheFrame:SetScript("OnEvent", refreshOwnedAuctionCache)

-- ============================================================================
-- Helpers
-- ============================================================================

local function itemIDFromLocation(loc)
  if not (loc and C_Item and C_Item.GetItemID) then return nil end
  local ok, id = pcall(C_Item.GetItemID, loc)
  if ok then return id end
  return nil
end

local function itemLinkFromLocation(loc)
  if not (loc and C_Item and C_Item.GetItemLink) then return nil end
  local ok, link = pcall(C_Item.GetItemLink, loc)
  if ok then return link end
  return nil
end

local function calculateDeposit(itemLocation, itemID, duration, quantity, isCommodity)
  if isCommodity then
    if not (C_AuctionHouse and C_AuctionHouse.CalculateCommodityDeposit) then return nil end
    if not itemID then return nil end
    local ok, deposit = pcall(C_AuctionHouse.CalculateCommodityDeposit, itemID, duration, quantity)
    return ok and deposit or nil
  end
  if not (C_AuctionHouse and C_AuctionHouse.CalculateItemDeposit) then return nil end
  if not itemLocation then return nil end
  local ok, deposit = pcall(C_AuctionHouse.CalculateItemDeposit, itemLocation, duration, quantity)
  return ok and deposit or nil
end

-- ============================================================================
-- Post emit
-- ============================================================================

local function onPost(itemLocation, duration, quantity, bid, buyout, isCommodity)
  if not Native.IsCaptureLive() then
    Native.skipCounters.posting_setup_gate = Native.skipCounters.posting_setup_gate + 1
    return
  end
  local itemID = itemIDFromLocation(itemLocation)
  local itemLink = itemLinkFromLocation(itemLocation)
  quantity = Native.SafeNum(quantity)
  if not itemID or quantity <= 0 then
    Native.skipCounters.posting_no_item = Native.skipCounters.posting_no_item + 1
    return
  end
  local deposit = calculateDeposit(itemLocation, itemID, duration, quantity, isCommodity)
  if not deposit or deposit <= 0 then
    Native.skipCounters.posting_no_deposit = Native.skipCounters.posting_no_deposit + 1
    return
  end

  local atTime = time()
  local charKey = Native.CurrentCharKey()
  -- %.0f instead of %d throughout: copper amounts on high-end items
  -- routinely exceed Lua's signed-32-bit %d ceiling (~2.1B copper /
  -- ~214,748g). %.0f accepts a Lua double and formats as a decimal
  -- integer with no fractional part — TLY-33.
  local hash = string.format("post|%s|%.0f|%.0f|%.0f|%.0f|%.0f",
    charKey, itemID, quantity,
    Native.SafeNum(bid), Native.SafeNum(buyout), atTime)

  local entry = {
    id = SOURCE_NAME .. ":ah-deposit:" .. hash,
    atTime = atTime,
    kind = "ah-deposit",
    itemID = itemID,
    charKey = charKey,
    copper = deposit,
    count = quantity,
    source = SOURCE_NAME,
    sourceId = "ah-deposit:" .. hash,
    meta = {
      itemLink = itemLink,
      bid = bid,
      buyout = buyout,
      deposit = deposit,
      duration = duration,
      isCommodity = isCommodity and true or false,
    },
  }

  local ok, err = ns.Ledger:Insert(entry)
  if ns.dbg then
    ns.dbg:PrintDebug(string.format("AHPosting: post %s x%d deposit=%.0f → %s",
      tostring(itemLink or itemID), quantity, deposit,
      ok and "inserted" or ("skipped: " .. tostring(err))))
  end
end

-- ============================================================================
-- Cancel emit
-- ============================================================================

local function onCancel(auctionID)
  if not Native.IsCaptureLive() then
    Native.skipCounters.cancel_setup_gate = Native.skipCounters.cancel_setup_gate + 1
    return
  end
  local info = auctionCache[auctionID]
  if not info and C_AuctionHouse and C_AuctionHouse.GetOwnedAuctionInfo then
    local ok, fresh = pcall(C_AuctionHouse.GetOwnedAuctionInfo, auctionID)
    if ok and type(fresh) == "table" then info = fresh end
  end
  if not info then
    Native.skipCounters.cancel_no_auction = Native.skipCounters.cancel_no_auction + 1
    return
  end

  local itemID = info.itemKey and info.itemKey.itemID or nil
  local quantity = Native.SafeNum(info.quantity) > 0 and info.quantity or 1
  local atTime = time()
  local charKey = Native.CurrentCharKey()
  local hash = string.format("cancel|%s|%.0f|%.0f|%.0f",
    charKey, auctionID, itemID or 0, atTime)

  local entry = {
    id = SOURCE_NAME .. ":ah-cancel:" .. hash,
    atTime = atTime,
    kind = "ah-cancel",
    itemID = itemID,
    charKey = charKey,
    copper = 0,  -- Lifecycle pairs with the original ah-deposit at view time.
    count = quantity,
    source = SOURCE_NAME,
    sourceId = "ah-cancel:" .. hash,
    meta = {
      auctionID = auctionID,
      bid = info.bidAmount or info.bid,
      buyout = info.buyoutAmount or info.buyout,
    },
  }

  local ok, err = ns.Ledger:Insert(entry)
  if ns.dbg then
    ns.dbg:PrintDebug(string.format("AHPosting: cancel auctionID=%.0f → %s",
      auctionID, ok and "inserted" or ("skipped: " .. tostring(err))))
  end
end

-- ============================================================================
-- Hook installation
-- ============================================================================

local hooksInstalled = false

local function installHooks()
  if hooksInstalled then return end
  if not (C_AuctionHouse and hooksecurefunc) then return end
  if C_AuctionHouse.PostItem then
    hooksecurefunc(C_AuctionHouse, "PostItem", function(item, duration, qty, bid, buyout)
      onPost(item, duration, qty, bid, buyout, false)
    end)
  end
  if C_AuctionHouse.PostCommodity then
    hooksecurefunc(C_AuctionHouse, "PostCommodity", function(item, duration, qty, unitPrice)
      onPost(item, duration, qty, nil, unitPrice, true)
    end)
  end
  if C_AuctionHouse.CancelAuction then
    hooksecurefunc(C_AuctionHouse, "CancelAuction", onCancel)
  end
  hooksInstalled = true
end

-- C_AuctionHouse exists at addon-load on retail. If a future patch puts it
-- behind a load-on-demand boundary, fall back to AUCTION_HOUSE_SHOW.
if C_AuctionHouse then
  installHooks()
else
  local installFrame = CreateFrame("Frame")
  installFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
  installFrame:SetScript("OnEvent", function(self)
    self:UnregisterAllEvents()
    installHooks()
  end)
end

Native:RegisterBucket({
  name = "ahposting",
  -- Pure event-driven; no scan() — entries arrive in real time.
})

Native.AHPosting = {
  RefreshOwnedAuctionCache = refreshOwnedAuctionCache,
}
