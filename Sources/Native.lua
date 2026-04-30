-- Tally — Sources/Native.lua
--
-- Tally's own observer of WoW transactions. Subscribes to game events that
-- carry transaction information and writes ledger entries directly. Makes
-- Tally functional with zero sibling-addon dependencies.
--
-- Pass 1 of this source covers AH mail invoices (sales + purchases) — the
-- highest-value native target since AH activity dominates the txn flow for
-- most auctioneers. Future passes can add merchant (vendor buy/sell),
-- repair (player money out at vendor), trade, and direct mail attachments.
--
-- Mail invoice scan only runs while the mail UI is open. Blizzard's
-- GetInboxInvoiceInfo is only valid after MAIL_INBOX_UPDATE arrives in an
-- open inbox. A mail invoice is one of two flavours:
--   "seller" — auction sold; payload includes buyout, deposit returned, AH cut
--   "buyer"  — auction won; payload includes amount paid
--
-- Stable hash across `(charKey, invoiceType, itemName, otherPlayer, bid,
-- buyout)` provides cross-session dedupe; identical invoices with the same
-- counter-party and amount collapse. Trade-off: unrecoverable if the same
-- player legitimately sells the same item to the same buyer at the same
-- price twice. Acceptable for V1.

local addonName, ns = ...

local Native = {}
ns.Sources = ns.Sources or {}
ns.Sources.Native = Native

local SOURCE_NAME = "tally-native"

local frame = CreateFrame("Frame")
local isMailOpen = false

-- ============================================================================
-- Helpers
-- ============================================================================

local function currentCharKey()
  local Cogworks = LibStub and LibStub("Cogworks-1.0", true)
  if Cogworks and Cogworks.GetCharacterKey then
    local ok, key = pcall(Cogworks.GetCharacterKey, Cogworks)
    if ok and key then return key end
  end
  local name = UnitName and UnitName("player") or ""
  local realm = GetRealmName and GetRealmName() or ""
  return name .. "-" .. realm
end

local function safeNum(n) return tonumber(n) or 0 end

-- ============================================================================
-- Mail invoice scanning
-- ============================================================================

-- Build a ledger entry from a single inbox invoice. Returns a ledger-shape
-- table (or nil if the invoice can't be classified). hash is the stable
-- per-row identifier; sourceId carries hash so dedupe works across sessions.
local function entryFromInvoice(charKey, invoiceType, itemName, otherPlayer,
                                bid, buyout, deposit, consignment)
  if not invoiceType or not itemName or itemName == "" then return nil end

  local hash = string.format("mail|%s|%s|%s|%s|%d|%d",
    charKey, invoiceType, itemName, otherPlayer or "",
    safeNum(bid), safeNum(buyout))

  local meta = {
    name = itemName,
    invoiceType = invoiceType,
    otherPlayer = otherPlayer,
    bid = bid,
    buyout = buyout,
    deposit = deposit,
    consignment = consignment,
  }

  if invoiceType == "seller" then
    local revenue = (buyout and buyout > 0) and buyout or (bid or 0)
    if revenue <= 0 then return nil end
    return {
      id = SOURCE_NAME .. ":sale:" .. hash,
      atTime = time(),
      kind = "sale",
      itemKey = nil,
      itemID = nil,
      charKey = charKey,
      copper = revenue,
      count = 1,
      source = SOURCE_NAME,
      sourceId = "sale:" .. hash,
      meta = meta,
    }
  elseif invoiceType == "buyer" then
    local cost = (buyout and buyout > 0) and buyout or (bid or 0)
    if cost <= 0 then return nil end
    return {
      id = SOURCE_NAME .. ":buy:" .. hash,
      atTime = time(),
      kind = "purchase",
      itemKey = nil,
      itemID = nil,
      charKey = charKey,
      copper = cost,
      count = 1,
      source = SOURCE_NAME,
      sourceId = "buy:" .. hash,
      meta = meta,
    }
  end

  return nil
end

-- Companion entry for the AH cut on seller invoices. Recorded as a separate
-- ah-fee ledger entry so income / expense totals reflect the gross sale
-- and the cut as distinct flows.
local function feeEntryFromInvoice(charKey, itemName, otherPlayer, bid, buyout, consignment)
  if not consignment or consignment <= 0 then return nil end
  local hash = string.format("mail-fee|%s|%s|%s|%d|%d",
    charKey, itemName, otherPlayer or "", safeNum(bid), safeNum(buyout))
  return {
    id = SOURCE_NAME .. ":ah-fee:" .. hash,
    atTime = time(),
    kind = "ah-fee",
    itemKey = nil,
    itemID = nil,
    charKey = charKey,
    copper = consignment,
    count = 1,
    source = SOURCE_NAME,
    sourceId = "ah-fee:" .. hash,
    meta = { name = itemName, ahCut = consignment },
  }
end

-- Scan the open mailbox for invoices and emit ledger entries for any that
-- aren't already recorded. Safe to call repeatedly — dedupe handles re-runs.
-- Returns (insertedCount, skippedCount) for parity with the source-import API.
local function scanInbox()
  if not isMailOpen then return 0, 0 end
  if not GetInboxNumItems then return 0, 0 end
  local n = GetInboxNumItems() or 0
  if n <= 0 then return 0, 0 end

  local charKey = currentCharKey()
  local entries = {}

  for i = 1, n do
    local okI, invoiceType, itemName, otherPlayer, bid, buyout, deposit, consignment
      = pcall(GetInboxInvoiceInfo, i)
    if okI and invoiceType and (invoiceType == "seller" or invoiceType == "buyer") then
      local main = entryFromInvoice(charKey, invoiceType, itemName, otherPlayer,
                                    bid, buyout, deposit, consignment)
      if main then entries[#entries + 1] = main end
      if invoiceType == "seller" then
        local fee = feeEntryFromInvoice(charKey, itemName, otherPlayer, bid, buyout, consignment)
        if fee then entries[#entries + 1] = fee end
      end
    end
  end

  if #entries == 0 then return 0, 0 end
  return ns.Ledger:InsertMany(entries)
end

-- ============================================================================
-- Event wiring
-- ============================================================================

frame:SetScript("OnEvent", function(_, event, ...)
  if event == "MAIL_SHOW" then
    isMailOpen = true
    -- Inbox data isn't necessarily fresh on MAIL_SHOW; the next
    -- MAIL_INBOX_UPDATE will trigger the actual scan.
  elseif event == "MAIL_CLOSED" then
    isMailOpen = false
  elseif event == "MAIL_INBOX_UPDATE" then
    if isMailOpen then
      pcall(scanInbox)
    end
  end
end)
frame:RegisterEvent("MAIL_SHOW")
frame:RegisterEvent("MAIL_CLOSED")
frame:RegisterEvent("MAIL_INBOX_UPDATE")

-- ============================================================================
-- Source registration
-- ============================================================================

-- Native source isn't "imported" the way a sibling-addon adapter is — it
-- writes entries inline as events fire. The import function exists so the
-- generic ImportFromAllSources flow doesn't skip it; it returns 0 unless
-- mail is currently open (in which case it does a fresh scan).
function Native:Register()
  if not ns.Ledger or not ns.Ledger.RegisterSource then return end
  ns.Ledger:RegisterSource(SOURCE_NAME, {
    label = "Tally (native events)",
    importFn = scanInbox,
    isAvailable = function() return true end,
  })
end

-- Exposed for testing.
Native.ScanInbox = scanInbox
Native.EntryFromInvoice = entryFromInvoice
