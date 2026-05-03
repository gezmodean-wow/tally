-- Tally — Sources/Native/Mail.lua
--
-- Native capture bucket: non-AH mail send/receive.
--
-- TLY-31 Phase A scope: hook `TakeInboxMoney` and `SendMail` to capture
-- money flowing through non-auction-house mail. Auction-house invoice mail
-- is handled by AHInvoice.lua and explicitly filtered out here so the same
-- mail doesn't get double-recorded.
--
-- Item attachments (mail-attach a stack of herbs to an alt) are NOT ledger
-- entries in V1 — items received in mail end up in bags, which Tally's
-- inventory rollup captures via Syndicator. Recording them as ledger rows
-- would treat inventory transfers as taxable events, which inflates net
-- worth churn without changing the bottom line. Future work could add
-- "trade with self" rows if cross-character cost-basis tracking turns out
-- to need them.
--
-- Postage cost and COD payments are out of scope for V1; the gross money
-- attached to the mail is what we record.

local addonName, ns = ...

local Native = ns.Sources and ns.Sources.Native
if not Native then return end

local SOURCE_NAME = Native.SOURCE_NAME

Native.skipCounters.mail_setup_gate    = 0
Native.skipCounters.mail_recv_no_money = 0
Native.skipCounters.mail_recv_invoice  = 0
Native.skipCounters.mail_send_no_money = 0

-- ============================================================================
-- Mail receive
-- ============================================================================

local function isInvoice(index)
  if not GetInboxInvoiceInfo then return false end
  local ok, invoiceType = pcall(GetInboxInvoiceInfo, index)
  return ok and (invoiceType == "seller" or invoiceType == "buyer")
end

local function onTakeInboxMoney(index)
  if not Native.IsCaptureLive() then
    Native.skipCounters.mail_setup_gate = Native.skipCounters.mail_setup_gate + 1
    return
  end
  if not (GetInboxHeaderInfo and index) then return end
  -- Filter AH-invoice mail; AHInvoice.lua owns those rows.
  if isInvoice(index) then
    Native.skipCounters.mail_recv_invoice = Native.skipCounters.mail_recv_invoice + 1
    return
  end

  local _, _, sender, subject, money = GetInboxHeaderInfo(index)
  money = Native.SafeNum(money)
  if money <= 0 then
    Native.skipCounters.mail_recv_no_money = Native.skipCounters.mail_recv_no_money + 1
    return
  end

  local atTime = time()
  local charKey = Native.CurrentCharKey()
  -- %.0f instead of %d: mail money attachments routinely exceed Lua's
  -- signed-32-bit %d ceiling (~214,748g). TLY-33.
  local hash = string.format("mail-recv|%s|%s|%s|%.0f|%.0f",
    charKey, sender or "?", subject or "", money, atTime)

  local entry = {
    id = SOURCE_NAME .. ":mail-receive:" .. hash,
    atTime = atTime,
    kind = "mail-receive",
    charKey = charKey,
    copper = money,
    count = 1,
    source = SOURCE_NAME,
    sourceId = "mail-receive:" .. hash,
    meta = { sender = sender, subject = subject },
  }

  local ok, err = ns.Ledger:Insert(entry)
  if ns.dbg then
    ns.dbg:PrintDebug(string.format("Mail: receive %s from %s money=%.0f → %s",
      tostring(subject), tostring(sender), money,
      ok and "inserted" or ("skipped: " .. tostring(err))))
  end
end

if hooksecurefunc and TakeInboxMoney then
  hooksecurefunc("TakeInboxMoney", onTakeInboxMoney)
end

-- ============================================================================
-- Mail send
-- ============================================================================

local function onSendMail(recipient, subject)
  if not Native.IsCaptureLive() then
    Native.skipCounters.mail_setup_gate = Native.skipCounters.mail_setup_gate + 1
    return
  end
  local money = GetSendMailMoney and Native.SafeNum(GetSendMailMoney()) or 0
  if money <= 0 then
    Native.skipCounters.mail_send_no_money = Native.skipCounters.mail_send_no_money + 1
    return
  end

  local atTime = time()
  local charKey = Native.CurrentCharKey()
  local hash = string.format("mail-send|%s|%s|%s|%.0f|%.0f",
    charKey, recipient or "?", subject or "", money, atTime)

  local entry = {
    id = SOURCE_NAME .. ":mail-send:" .. hash,
    atTime = atTime,
    kind = "mail-send",
    charKey = charKey,
    copper = money,
    count = 1,
    source = SOURCE_NAME,
    sourceId = "mail-send:" .. hash,
    meta = { recipient = recipient, subject = subject },
  }

  local ok, err = ns.Ledger:Insert(entry)
  if ns.dbg then
    ns.dbg:PrintDebug(string.format("Mail: send to %s money=%.0f → %s",
      tostring(recipient), money,
      ok and "inserted" or ("skipped: " .. tostring(err))))
  end
end

if hooksecurefunc and SendMail then
  hooksecurefunc("SendMail", onSendMail)
end

Native:RegisterBucket({
  name = "mail",
})
