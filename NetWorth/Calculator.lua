-- Tally — NetWorth/Calculator.lua
--
-- Sums gold + valued items + tokens across all characters and the warband.
-- Strategy is a TSM price expression stored at TallyDB.netWorth.strategy.
-- Default: "DBRegionMarketAvg" (regional average; not server-specific).

local addonName, ns = ...

local NetWorth = {}
ns.NetWorth = NetWorth

local DEFAULT_STRATEGY = "DBRegionMarketAvg"

local function strategy()
  TallyDB.netWorth = TallyDB.netWorth or {}
  if not TallyDB.netWorth.strategy or TallyDB.netWorth.strategy == "" then
    TallyDB.netWorth.strategy = DEFAULT_STRATEGY
  end
  return TallyDB.netWorth.strategy
end

function NetWorth:GetStrategy()
  return strategy()
end

function NetWorth:SetStrategy(expression)
  if not ns.Pricing:IsValidStrategy(expression) then
    return false, "invalid TSM price expression"
  end
  TallyDB.netWorth = TallyDB.netWorth or {}
  TallyDB.netWorth.strategy = expression
  return true
end

-- Returns a structured snapshot.
--   opts.includeBound = true → owned-worth view (counts bound items too).
--                       false (default) → net-worth view (saleable only).
function NetWorth:Snapshot(opts)
  local includeBound = opts and opts.includeBound or false
  local valueOpts = { countField = includeBound and "total" or "saleable" }
  local rollup = ns.Inventory:Get()
  local s = strategy()
  local snapshot = {
    view = includeBound and "owned" or "net",
    total = 0, gold = 0, items = 0,
    breakdown = { tsm = 0, token = 0, vendor = 0, none = 0 },
    byCharacter = {},
    warband = { gold = 0, items = 0, total = 0 },
    strategy = s,
  }
  if not rollup then return snapshot end

  for charKey, char in pairs(rollup.characters or {}) do
    local itemValue, breakdown = ns.Pricing:ValueItemMap(char.items or {}, s, valueOpts)
    snapshot.byCharacter[charKey] = {
      gold = char.gold or 0,
      items = itemValue,
      total = (char.gold or 0) + itemValue,
    }
    snapshot.gold = snapshot.gold + (char.gold or 0)
    snapshot.items = snapshot.items + itemValue
    for k, v in pairs(breakdown) do snapshot.breakdown[k] = (snapshot.breakdown[k] or 0) + v end
  end

  if rollup.warband then
    local itemValue, breakdown = ns.Pricing:ValueItemMap(rollup.warband.items or {}, s, valueOpts)
    snapshot.warband.gold = rollup.warband.gold or 0
    snapshot.warband.items = itemValue
    snapshot.warband.total = snapshot.warband.gold + itemValue
    snapshot.gold = snapshot.gold + snapshot.warband.gold
    snapshot.items = snapshot.items + itemValue
    for k, v in pairs(breakdown) do snapshot.breakdown[k] = (snapshot.breakdown[k] or 0) + v end
  end

  snapshot.total = snapshot.gold + snapshot.items
  return snapshot
end

local function formatGold(copper)
  copper = math.floor(copper or 0)
  local gold = math.floor(copper / 10000)
  local silver = math.floor((copper % 10000) / 100)
  local copperRemainder = copper % 100
  if gold > 0 then
    return string.format("%s|cffffd700g|r %d|cffc7c7cfs|r %d|cffeda55fc|r",
      BreakUpLargeNumbers and BreakUpLargeNumbers(gold) or tostring(gold), silver, copperRemainder)
  elseif silver > 0 then
    return string.format("%d|cffc7c7cfs|r %d|cffeda55fc|r", silver, copperRemainder)
  else
    return string.format("%d|cffeda55fc|r", copperRemainder)
  end
end

NetWorth.FormatGold = formatGold

-- Pretty-print an arbitrary snapshot (current or reconstructed). headerSuffix
-- is appended to the title line — useful for "(at 2026-04-21 14:30)" on
-- historical snapshots.
function NetWorth:PrintSnapshot(snap, headerSuffix)
  local prefix = "|cff7fbfffTally|r"
  local label = snap.view == "owned" and "owned worth (incl. bound)" or "net worth (saleable only)"
  local header = label .. " — " .. snap.strategy
  if headerSuffix and headerSuffix ~= "" then header = header .. " " .. headerSuffix end
  print(prefix .. " " .. header .. ":")
  print("  Total: " .. formatGold(snap.total))
  print("    Gold: " .. formatGold(snap.gold))
  print("    Items: " .. formatGold(snap.items))
  if snap.breakdown and snap.breakdown.none and snap.breakdown.none > 0 then
    print("    |cffff8080Unpriced items:|r " .. formatGold(snap.breakdown.none))
  end
  if snap.warband and snap.warband.total > 0 then
    print("  Warband: " .. formatGold(snap.warband.total)
      .. " (" .. formatGold(snap.warband.gold) .. " gold + " .. formatGold(snap.warband.items) .. " items)")
  end
  local chars = {}
  for k, v in pairs(snap.byCharacter or {}) do chars[#chars + 1] = { key = k, data = v } end
  table.sort(chars, function(a, b) return a.data.total > b.data.total end)
  for _, c in ipairs(chars) do
    print(string.format("  %s: %s (%s gold + %s items)",
      c.key, formatGold(c.data.total), formatGold(c.data.gold), formatGold(c.data.items)))
  end
end

function NetWorth:Print(opts)
  self:PrintSnapshot(self:Snapshot(opts))
end
