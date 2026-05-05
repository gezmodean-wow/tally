-- Tally — Sources/Native/Vendor.lua
--
-- Native capture bucket: merchant interactions (vendor sell + vendor buy).
--
-- TLY-31 Phase A scope: snapshot bag contents + money on MERCHANT_SHOW,
-- diff against the post-state on MERCHANT_CLOSED, and emit one vendor-sell
-- row per itemID with negative bag delta, one vendor-buy row per itemID
-- with positive bag delta. The whole vendor session is collapsed into one
-- pair-of-rows-per-item; per-transaction granularity is sacrificed for V1
-- simplicity. Players who need per-transaction detail can run Journalator
-- alongside (it's still a registered backfill source).
--
-- Sell copper: itemSellPrice (from `C_Item.GetItemInfo`) × delta count.
-- Buy copper:  unit price from the merchant inventory snapshot (taken on
-- MERCHANT_SHOW since GetMerchantItemInfo is invalid after MERCHANT_CLOSED).
--
-- Money-delta cross-check: SUM(sell rows) - SUM(buy rows) should equal the
-- session's actual money delta. If they disagree (e.g. extended-cost items,
-- buyback, repair), the residual is logged via dbg:PrintDebug for triage.

local addonName, ns = ...

local Native = ns.Sources and ns.Sources.Native
if not Native then return end

local SOURCE_NAME = Native.SOURCE_NAME

-- Skip-counter slots
Native.skipCounters.vendor_no_snapshot   = 0
Native.skipCounters.vendor_setup_gate    = 0
Native.skipCounters.vendor_no_sell_price = 0
Native.skipCounters.vendor_no_buy_price  = 0

-- ============================================================================
-- Snapshot helpers
-- ============================================================================

-- Walk bags 0-4 (and 5 if it exists — reagent bag) building an itemID→count
-- map. Caller filters / ignores any items that lack a numeric itemID. Uses
-- C_Container if present (modern client), with the deprecated globals as a
-- fallback for the (unlikely) event where a future patch removes the legacy
-- functions before the new ones are universally rolled out.
local function snapshotBags()
  local snap = {}
  local maxBag = 4
  if NUM_BAG_SLOTS then maxBag = NUM_BAG_SLOTS end
  for bag = 0, maxBag do
    local numSlots = (C_Container and C_Container.GetContainerNumSlots
                       and C_Container.GetContainerNumSlots(bag))
                  or (GetContainerNumSlots and GetContainerNumSlots(bag))
                  or 0
    for slot = 1, numSlots do
      local info
      if C_Container and C_Container.GetContainerItemInfo then
        info = C_Container.GetContainerItemInfo(bag, slot)
      end
      if info and info.itemID then
        snap[info.itemID] = (snap[info.itemID] or 0) + (info.stackCount or 1)
      end
    end
  end
  return snap
end

-- Snapshot the merchant's wares so we have a per-itemID buy-price reference
-- even after MERCHANT_CLOSED invalidates the merchant API.
local function snapshotMerchant()
  local snap = {}
  if not (GetMerchantNumItems and GetMerchantItemInfo and GetMerchantItemLink) then
    return snap
  end
  local n = GetMerchantNumItems() or 0
  for i = 1, n do
    local link = GetMerchantItemLink(i)
    local _, _, price, quantity = GetMerchantItemInfo(i)
    if link and price and price > 0 and quantity and quantity > 0 then
      local itemID = tonumber(link:match("item:(%d+)"))
      if itemID then
        snap[itemID] = { unitPrice = price / quantity, link = link }
      end
    end
  end
  return snap
end

-- ============================================================================
-- Capture state
-- ============================================================================

local pre = {
  bags     = nil,
  money    = nil,
  merchant = nil,
  openedAt = nil,
}

local function clearPre()
  pre.bags, pre.money, pre.merchant, pre.openedAt = nil, nil, nil, nil
end

-- ============================================================================
-- Diff + emit
-- ============================================================================

local function emitDiff()
  if not pre.bags then
    Native.skipCounters.vendor_no_snapshot = Native.skipCounters.vendor_no_snapshot + 1
    return
  end
  if not Native.IsCaptureLive() then
    Native.skipCounters.vendor_setup_gate = Native.skipCounters.vendor_setup_gate + 1
    clearPre()
    return
  end

  local post = snapshotBags()
  local atTime = time()
  local charKey = Native.CurrentCharKey()
  local entries = {}
  local sellTotal, buyTotal = 0, 0

  -- Union of itemIDs across both snapshots
  local seen = {}
  for id in pairs(pre.bags) do seen[id] = true end
  for id in pairs(post) do seen[id] = true end

  for itemID in pairs(seen) do
    local before = pre.bags[itemID] or 0
    local after  = post[itemID] or 0
    local delta = after - before
    if delta ~= 0 then
      local kind, count
      if delta < 0 then
        kind = "vendor-sell"
        count = -delta
      else
        kind = "vendor-buy"
        count = delta
      end

      local copper = 0
      if kind == "vendor-sell" then
        local sellPrice = select(11, GetItemInfo(itemID))
        if sellPrice and sellPrice > 0 then
          copper = sellPrice * count
        else
          Native.skipCounters.vendor_no_sell_price = Native.skipCounters.vendor_no_sell_price + 1
        end
        sellTotal = sellTotal + copper
      else
        local merchInfo = pre.merchant and pre.merchant[itemID]
        if merchInfo and merchInfo.unitPrice then
          copper = math.floor(merchInfo.unitPrice * count + 0.5)
        else
          Native.skipCounters.vendor_no_buy_price = Native.skipCounters.vendor_no_buy_price + 1
        end
        buyTotal = buyTotal + copper
      end

      -- %.0f instead of %d: itemID + count are bounded but atTime as
      -- epoch seconds is fine; consistency + future-proofing. TLY-33.
      local hash = string.format("vendor|%s|%s|%.0f|%.0f|%.0f",
        charKey, kind, itemID, count, atTime)

      entries[#entries + 1] = {
        id = SOURCE_NAME .. ":" .. kind .. ":" .. hash,
        atTime = atTime,
        kind = kind,
        itemID = itemID,
        charKey = charKey,
        copper = copper,
        count = count,
        source = SOURCE_NAME,
        sourceId = kind .. ":" .. hash,
        meta = {
          merchantLink = pre.merchant and pre.merchant[itemID] and pre.merchant[itemID].link or nil,
        },
      }
    end
  end

  if #entries > 0 then
    local inserted, _ = ns.Ledger:InsertMany(entries)
    if ns.dbg then
      local moneyDelta = (GetMoney and GetMoney() or 0) - (pre.money or 0)
      local residual = moneyDelta - (sellTotal - buyTotal)
      ns.dbg:PrintDebug(string.format(
        "Vendor: closed session — sells=%.0f buys=%.0f money=%+.0f residual=%+.0f (inserted %d rows)",
        sellTotal, buyTotal, moneyDelta, residual, inserted or 0))
    end
  end

  clearPre()
end

-- ============================================================================
-- Event wiring
-- ============================================================================

local frame = CreateFrame("Frame")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("MERCHANT_CLOSED")
frame:SetScript("OnEvent", function(_, event)
  if event == "MERCHANT_SHOW" then
    pre.bags     = snapshotBags()
    pre.money    = GetMoney and GetMoney() or 0
    pre.merchant = snapshotMerchant()
    pre.openedAt = time()
  elseif event == "MERCHANT_CLOSED" then
    pcall(emitDiff)
  end
end)

Native:RegisterBucket({
  name = "vendor",
  -- Pure event-driven; entries land at MERCHANT_CLOSED.
})

Native.Vendor = {
  SnapshotBags     = snapshotBags,
  SnapshotMerchant = snapshotMerchant,
}
