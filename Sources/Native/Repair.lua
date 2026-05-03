-- Tally — Sources/Native/Repair.lua
--
-- Native capture bucket: gear repair via `RepairAllItems`.
--
-- TLY-31 Phase A scope: hook `RepairAllItems(useGuildBank)` and emit a
-- `repair` ledger row with copper = pre-repair money minus post-repair
-- money. We sample money at hook-fire time and again ~100ms later via a
-- C_Timer.After so the server's money packet has settled. The alternative
-- (subscribing to PLAYER_MONEY) races against any unrelated money change
-- that happens to arrive between the hook and the event.
--
-- useGuildBank == true means the guild paid; we emit a row with copper=0
-- and meta.useGuildBank=true so the activity is still recorded but the
-- player's expense totals stay accurate.
--
-- Per-item repairs (clicking individual gear at the merchant) go through a
-- different code path and are out of scope for V1. They're rare; bulk
-- repair is the dominant case.

local addonName, ns = ...

local Native = ns.Sources and ns.Sources.Native
if not Native then return end

local SOURCE_NAME = Native.SOURCE_NAME

Native.skipCounters.repair_setup_gate = 0
Native.skipCounters.repair_zero_cost  = 0

local function emitRepair(cost, useGuildBank)
  if not Native.IsCaptureLive() then
    Native.skipCounters.repair_setup_gate = Native.skipCounters.repair_setup_gate + 1
    return
  end
  cost = Native.SafeNum(cost)
  if cost <= 0 and not useGuildBank then
    Native.skipCounters.repair_zero_cost = Native.skipCounters.repair_zero_cost + 1
    return
  end

  local atTime = time()
  local charKey = Native.CurrentCharKey()
  -- %.0f instead of %d: copper costs exceed signed-32-bit ceiling for
  -- guild-bank repairs at endgame. TLY-33.
  local hash = string.format("repair|%s|%.0f|%.0f|%s",
    charKey, atTime, cost, useGuildBank and "guild" or "player")

  local entry = {
    id = SOURCE_NAME .. ":repair:" .. hash,
    atTime = atTime,
    kind = "repair",
    charKey = charKey,
    copper = useGuildBank and 0 or cost,
    count = 1,
    source = SOURCE_NAME,
    sourceId = "repair:" .. hash,
    meta = { useGuildBank = useGuildBank and true or false },
  }

  local ok, err = ns.Ledger:Insert(entry)
  if ns.dbg then
    ns.dbg:PrintDebug(string.format("Repair: cost=%.0f guild=%s → %s",
      cost, tostring(useGuildBank), ok and "inserted" or ("skipped: " .. tostring(err))))
  end
end

if hooksecurefunc and RepairAllItems and C_Timer and C_Timer.After then
  hooksecurefunc("RepairAllItems", function(useGuildBank)
    local before = GetMoney and GetMoney() or 0
    C_Timer.After(0.1, function()
      local after = GetMoney and GetMoney() or 0
      local cost = before - after
      emitRepair(cost, useGuildBank)
    end)
  end)
end

Native:RegisterBucket({
  name = "repair",
})
