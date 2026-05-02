-- Tally — Sources/Native/AHInvoice.lua
--
-- Native capture bucket: auction-house mail invoices.
--
-- Mail invoices are the highest-volume native target since AH activity
-- dominates the txn flow for most auctioneers. Blizzard's
-- GetInboxInvoiceInfo is only valid after MAIL_INBOX_UPDATE arrives in an
-- open inbox, so this bucket runs scans on:
--
--   * MAIL_INBOX_UPDATE while mail is open (live capture)
--   * The bucket's `scan()` registered with the orchestrator (manual
--     "Import now" / login backfill — only meaningful if mail is open)
--
-- Each invoice is one of two flavours:
--   "seller" — auction sold; payload includes buyout + AH cut (consignment)
--   "buyer"  — auction won; payload includes amount paid
--
-- Stable hash across `(charKey, invoiceType, itemName, otherPlayer, bid,
-- buyout)` provides cross-session dedupe; identical invoices with the same
-- counter-party and amount collapse. Trade-off: unrecoverable if the same
-- player legitimately sells the same item to the same buyer at the same
-- price twice. Acceptable for V1.

local addonName, ns = ...

local Native = ns.Sources and ns.Sources.Native
if not Native then return end

local SOURCE_NAME = Native.SOURCE_NAME

-- Pre-create skip-counter slots so /tally diag sees stable keys even before
-- any activity has fired.
Native.skipCounters.invoice_no_item_name     = 0
Native.skipCounters.invoice_zero_revenue     = 0
Native.skipCounters.invoice_bad_invoice_type = 0

local frame = CreateFrame("Frame")
local isMailOpen = false

-- Build a ledger entry from a single inbox invoice. Returns a ledger-shape
-- table (or nil if the invoice can't be classified). hash is the stable
-- per-row identifier; sourceId carries hash so dedupe works across sessions.
local function entryFromInvoice(charKey, invoiceType, itemName, otherPlayer,
                                bid, buyout, deposit, consignment)
  if not invoiceType or not itemName or itemName == "" then
    Native.skipCounters.invoice_no_item_name = Native.skipCounters.invoice_no_item_name + 1
    return nil
  end

  local hash = string.format("mail|%s|%s|%s|%s|%d|%d",
    charKey, invoiceType, itemName, otherPlayer or "",
    Native.SafeNum(bid), Native.SafeNum(buyout))

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
    if revenue <= 0 then
      Native.skipCounters.invoice_zero_revenue = Native.skipCounters.invoice_zero_revenue + 1
      return nil
    end
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
    if cost <= 0 then
      Native.skipCounters.invoice_zero_revenue = Native.skipCounters.invoice_zero_revenue + 1
      return nil
    end
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

  Native.skipCounters.invoice_bad_invoice_type = Native.skipCounters.invoice_bad_invoice_type + 1
  return nil
end

-- Companion entry for the AH cut on seller invoices. Recorded as a separate
-- ah-fee ledger entry so income / expense totals reflect the gross sale and
-- the cut as distinct flows.
local function feeEntryFromInvoice(charKey, itemName, otherPlayer, bid, buyout, consignment)
  if not consignment or consignment <= 0 then return nil end
  local hash = string.format("mail-fee|%s|%s|%s|%d|%d",
    charKey, itemName, otherPlayer or "", Native.SafeNum(bid), Native.SafeNum(buyout))
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
-- Returns (insertedCount, skippedCount).
local function scanInbox()
  if not isMailOpen then return 0, 0 end
  if not Native.IsCaptureLive() then return 0, 0 end
  if not GetInboxNumItems then return 0, 0 end
  local n = GetInboxNumItems() or 0
  if n <= 0 then return 0, 0 end

  local charKey = Native.CurrentCharKey()
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
  if ns.dbg then ns.dbg:PrintDebug(string.format("AHInvoice: scanInbox found %d entries", #entries)) end
  return ns.Ledger:InsertMany(entries)
end

frame:SetScript("OnEvent", function(_, event)
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

Native:RegisterBucket({
  name = "ahinvoice",
  scan = scanInbox,
})

-- Exposed for tests + sibling-cog probes.
Native.AHInvoice = {
  ScanInbox       = scanInbox,
  EntryFromInvoice = entryFromInvoice,
}
