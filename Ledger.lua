-- Tally — Ledger.lua
--
-- Source registry + transaction taxonomy for the projection-layer redesign
-- (TLY-77/-78). Tally no longer *stores* a ledger: the alpha18/19 active
-- blob + monthly archive slots + import/synthesis machinery were retired in
-- TLY-78. What survives here is the source-agnostic vocabulary the data
-- spine is built on:
--
--   * Kinds        — the canonical transaction-kind enum.
--   * Schema       — per-(kind, source) field declarations.
--   * Authority    — per-(kind, field) source priority, consumed by the
--                    spine's merge pass (Spine/Dedup.lua reuses GetAuthority
--                    rather than duplicating the priority tables).
--   * Source registry — adapters register a getEntriesFn here; the spine's
--                    ParseCache parses each registered, available source
--                    once per session. This is the *only* data path now —
--                    no native capture, no stored rows.
--
-- The old read API (Reconcile / Query / Stats) is preserved as thin shims
-- over Spine/UnifiedLedger so the Cogworks public API and Research keep
-- working on the recompute-on-parse unified ledger without code changes at
-- their call sites.
--
-- Entry shape (produced by adapter getEntriesFns, consumed by the spine):
--   {
--     id        = "<source>:<sourceId>",   -- unique per real-world record
--     atTime    = epoch,                   -- when the txn happened
--     kind      = "sale" | "purchase" | ... (see Ledger.Kinds),
--     itemKey   = "12345;bonus;mods",      -- canonical key (or nil)
--     itemID    = 12345,                   -- numeric for fast lookup
--     charKey   = "Hugemane-Stormrage",    -- per-character; "Warband" is
--                                           -- a synthetic charKey
--     copper    = 50000,                   -- gross amount in copper
--     count     = 1,                       -- quantity transacted
--     source    = "flipqueue",             -- adapter name
--     sourceId  = "abc123",                -- stable identifier within source
--     meta      = { ... },                 -- source-specific extras
--   }

local addonName, ns = ...

local Ledger = {}
ns.Ledger = Ledger

-- Canonical kind enum exposed for adapters and UI filters.
--
-- Phase-1 kinds: sale, purchase, ah-cancel, ah-expire, ah-fee, vendor-sell,
-- vendor-buy, mail-receive, mail-send, trade, repair, refund.
--
-- Phase-2 kinds (TLY-23, sourced primarily from Journalator): ah-deposit
-- (post-time escrow paired with sale/expire/cancel at view time), taxi,
-- trainer, quest-reward, loot, mission, trading-post, crafting-order-placed,
-- crafting-order-fulfilled.
--
-- Unknown (TLY-29): catch-all for adapter rows with a source-kind we
-- don't recognize. Routes unknowns into the ledger as `kind = "unknown"`
-- with the original payload preserved in `meta.sourceKind` instead of
-- silently dropping or falling back to a wrong kind. Neutral sign — the
-- row is queryable + diagnostic but doesn't affect P&L.
Ledger.Kinds = {
  Sale                    = "sale",
  Purchase                = "purchase",
  AhCancel                = "ah-cancel",
  AhExpire                = "ah-expire",
  AhFee                   = "ah-fee",
  AhDeposit               = "ah-deposit",
  VendorSell              = "vendor-sell",
  VendorBuy               = "vendor-buy",
  MailReceive             = "mail-receive",
  MailSend                = "mail-send",
  Trade                   = "trade",
  Repair                  = "repair",
  Refund                  = "refund",
  Taxi                    = "taxi",
  Trainer                 = "trainer",
  QuestReward             = "quest-reward",
  Loot                    = "loot",
  Mission                 = "mission",
  TradingPost             = "trading-post",
  CraftingOrderPlaced     = "crafting-order-placed",
  CraftingOrderFulfilled  = "crafting-order-fulfilled",
  Unknown                 = "unknown",
}

-- ============================================================================
-- Schema (TLY-29)
-- ============================================================================
--
-- Per-(kind, source) field declaration: documents which fields each
-- adapter populates for each kind. Used as living documentation +
-- introspection surface for /tally diag and by the spine's merge pass
-- (which needs to know which fields a given source can authoritatively
-- supply for each kind).
--
-- Schema is *additive*. Adapters keep writing the same `meta` tables
-- they always have; this table just describes them so consumers can
-- query "what does FlipQueue carry on a sale row?" without grepping the
-- adapter code.
--
-- `canonical` lists the top-level entry fields every adapter is expected
-- to populate for that kind. Universal fields (id, atTime, kind, source,
-- sourceId) are validated at insert time and omitted here for brevity.
--
-- `sourceFields` lists the meta keys each adapter populates. Missing
-- entries mean "this adapter doesn't emit this kind." Empty list means
-- "this adapter emits this kind but writes no source-specific extras."
--
-- The `unknown` kind has no sourceFields predeclared — by definition we
-- don't know the shape — but every Unknown row MUST carry `meta.sourceKind`
-- (the original source-kind string the adapter saw before routing).
--
-- The `tally-native` source columns are retained for documentation / merge
-- priority even though native capture was retired in TLY-78: a player who
-- still has pre-redesign native rows in a sibling export, or a future
-- capture-only cog, can still feed them through the same authority order.
local ITEM_TXN_CANONICAL = { "itemID", "itemKey", "charKey", "copper", "count" }
local NON_ITEM_CANONICAL = { "charKey", "copper" }

Ledger.Schema = {
  sale = {
    canonical = ITEM_TXN_CANONICAL,
    sourceFields = {
      ["tally-native"] = { "name", "ahCut" },
      flipqueue       = { "name", "icon", "quality", "targetRealm",
                          "postedPrice", "expectedPrice", "auctionStatus",
                          "saleOutcome", "ahFee", "totalFeesSpent",
                          "postAttempts", "postHistory", "postedAt" },
      tsm             = { "itemString", "stackSize", "otherPlayer",
                          "unitPrice", "tsmSource", "csvName" },
      journalator     = { "name", "itemLink", "buyout", "deposit" },
    },
  },
  purchase = {
    canonical = ITEM_TXN_CANONICAL,
    sourceFields = {
      ["tally-native"] = { "name" },
      flipqueue       = { "name", "icon", "quality", "targetRealm",
                          "auctionStatus", "saleOutcome", "ahFee",
                          "postAttempts", "postHistory", "postedAt" },
      tsm             = { "itemString", "stackSize", "otherPlayer",
                          "unitPrice", "tsmSource", "csvName" },
      journalator     = { "name", "itemLink" },
    },
  },
  ["ah-cancel"] = {
    canonical = ITEM_TXN_CANONICAL,
    sourceFields = {
      flipqueue   = { "name", "auctionStatus", "ahFee", "postedAt" },
      tsm         = { "itemString", "stackSize", "csvName" },
      journalator = { "name", "itemLink", "failedType" },
    },
  },
  ["ah-expire"] = {
    canonical = ITEM_TXN_CANONICAL,
    sourceFields = {
      flipqueue   = { "name", "auctionStatus", "ahFee", "postedAt" },
      tsm         = { "itemString", "stackSize", "csvName" },
      journalator = { "name", "itemLink", "failedType" },
    },
  },
  ["ah-fee"] = {
    canonical = ITEM_TXN_CANONICAL,
    sourceFields = {
      journalator = { "name", "itemLink" },
    },
  },
  ["ah-deposit"] = {
    canonical = ITEM_TXN_CANONICAL,
    sourceFields = {
      ["tally-native"] = { "name", "buyout", "bid", "deposit" },
      journalator      = { "name", "itemLink", "buyout", "bid", "deposit" },
    },
  },
  ["vendor-sell"] = {
    canonical = ITEM_TXN_CANONICAL,
    sourceFields = {
      ["tally-native"] = { "merchantLink" },
      tsm              = { "itemString", "stackSize", "unitPrice", "tsmSource", "csvName" },
      journalator      = { "name", "itemLink", "vendorType" },
    },
  },
  ["vendor-buy"] = {
    canonical = ITEM_TXN_CANONICAL,
    sourceFields = {
      ["tally-native"] = { "merchantLink" },
      tsm              = { "itemString", "stackSize", "unitPrice", "tsmSource", "csvName" },
      journalator      = { "name", "itemLink", "vendorType" },
    },
  },
  ["mail-receive"] = {
    canonical = NON_ITEM_CANONICAL,
    sourceFields = {
      ["tally-native"] = { "sender", "subject" },
      journalator      = { "recipient", "sender", "items" },
    },
  },
  ["mail-send"] = {
    canonical = NON_ITEM_CANONICAL,
    sourceFields = {
      ["tally-native"] = { "recipient", "subject" },
      journalator      = { "recipient", "sender", "items" },
    },
  },
  trade = {
    canonical = NON_ITEM_CANONICAL,
    sourceFields = {
      journalator = { "partner", "moneyIn", "moneyOut", "itemsIn", "itemsOut" },
    },
  },
  repair = {
    canonical = NON_ITEM_CANONICAL,
    sourceFields = {
      ["tally-native"] = { "useGuildBank" },
      journalator      = {},
    },
  },
  refund = {
    canonical = ITEM_TXN_CANONICAL,
    sourceFields = {},  -- no producer yet; reserved
  },
  taxi = {
    canonical = NON_ITEM_CANONICAL,
    sourceFields = {
      journalator = { "origin", "target", "zone", "map" },
    },
  },
  trainer = {
    canonical = NON_ITEM_CANONICAL,
    sourceFields = {
      journalator = {},
    },
  },
  ["quest-reward"] = {
    canonical = ITEM_TXN_CANONICAL,
    sourceFields = {
      journalator = {},
    },
  },
  loot = {
    canonical = ITEM_TXN_CANONICAL,
    sourceFields = {
      journalator = {},
    },
  },
  mission = {
    canonical = ITEM_TXN_CANONICAL,
    sourceFields = {
      journalator = { "missionName", "missionID", "rewards" },
    },
  },
  ["trading-post"] = {
    canonical = NON_ITEM_CANONICAL,
    sourceFields = {
      journalator = { "itemName", "itemLink", "currencyCost" },
    },
  },
  ["crafting-order-placed"] = {
    canonical = ITEM_TXN_CANONICAL,
    sourceFields = {
      journalator = {},
    },
  },
  ["crafting-order-fulfilled"] = {
    canonical = ITEM_TXN_CANONICAL,
    sourceFields = {
      journalator = {},
    },
  },
  -- TLY-29: catch-all kind for adapter rows whose source-kind we don't
  -- recognize. No predeclared sourceFields — every Unknown row carries
  -- the original source-kind string in meta.sourceKind so consumers can
  -- distinguish "TSM Trade row we don't yet support" from "FlipQueue
  -- in-flight active status" by inspection.
  unknown = {
    canonical = { "source", "sourceId" },
    sourceFields = {},
    metaRequired = { "sourceKind" },
  },
}

-- Returns the schema entry for a kind (canonical + sourceFields) or nil
-- if the kind is unrecognized. Used by /tally diag introspection and by
-- the spine's merge pass to decide which fields a given source can
-- authoritatively supply.
function Ledger:GetSchema(kind)
  return Ledger.Schema[kind]
end

-- Build a ledger entry routed to Kinds.Unknown. Adapters use this when
-- the underlying source emitted a status / source / kind string the
-- adapter doesn't recognize. Preserves the original source-kind on
-- meta.sourceKind so the row stays diagnostically useful.
--
-- Required fields in `attrs`: source, sourceId, atTime, sourceKind.
-- Optional: charKey, itemID, itemKey, copper, count, meta (extra fields
-- merged into meta beneath sourceKind).
--
-- Returns the entry table (caller appends to its entries list) or nil if
-- required fields are missing.
function Ledger:BuildUnknownEntry(attrs)
  if type(attrs) ~= "table" then return nil end
  if type(attrs.source) ~= "string" or attrs.source == "" then return nil end
  if type(attrs.sourceId) ~= "string" or attrs.sourceId == "" then return nil end
  if type(attrs.atTime) ~= "number" or attrs.atTime <= 0 then return nil end
  if type(attrs.sourceKind) ~= "string" or attrs.sourceKind == "" then return nil end
  local meta = {}
  if type(attrs.meta) == "table" then
    for k, v in pairs(attrs.meta) do meta[k] = v end
  end
  meta.sourceKind = attrs.sourceKind
  return {
    id       = attrs.source .. ":unknown:" .. attrs.sourceId,
    atTime   = attrs.atTime,
    kind     = Ledger.Kinds.Unknown,
    itemID   = attrs.itemID,
    itemKey  = attrs.itemKey,
    charKey  = attrs.charKey,
    copper   = attrs.copper or 0,
    count    = attrs.count or 1,
    source   = attrs.source,
    sourceId = "unknown:" .. attrs.sourceId,
    meta     = meta,
  }
end

-- ============================================================================
-- Authority (TLY-30)
-- ============================================================================
--
-- Authority: per-(kind, field) source priority. When two or more adapters
-- captured the same real-world event, the spine's merge pass merges them
-- into one record by picking each canonical field from the highest-priority
-- source that has a non-nil value for it. The selection is per-field, not
-- per-row, so a single merged record can have atTime from one source and
-- copper from another (TSM, which knows the AH cut precisely).
--
-- Sources not listed for a (kind, field) tuple fall back to the global
-- DEFAULT_PRIORITY ordering. Rationale for the defaults:
--
--   tally-native — event-driven, captured the instant the event fires;
--                  most reliable for atTime and field presence in general.
--   journalator  — also live, captures alongside Native; very close in
--                  fidelity but second so we don't double-count when
--                  Native already saw the event.
--   tsm          — periodic CSV write; lossy on atTime (TSM rounds to
--                  the second of the source event but its writes can
--                  lag), but uniquely accurate on copper for sales
--                  because it accounts for the AH cut at write time.
--   flipqueue    — derived from FlipQueue's posting-flow log; rich on
--                  posting metadata (postedPrice, postHistory, etc.)
--                  but financial fields are downstream of what the
--                  user sees in mail, so they trail Native + TSM.
--
-- Per-(kind, field) overrides express the cases where the default is
-- wrong — most importantly `sale.copper` where TSM beats everyone else.
local DEFAULT_PRIORITY = { "tally-native", "journalator", "tsm", "flipqueue" }

Ledger.Authority = {
  sale = {
    -- atTime: Native sees the mail invoice the instant the inbox
    -- updates; Journalator hooks the same path; TSM's CSV row carries
    -- the source-event time but writes lag.
    atTime = { "tally-native", "journalator", "tsm", "flipqueue" },
    -- copper: TSM's CSV records final post-cut amount with no rounding
    -- ambiguity; Native sees the mail invoice's gross + cut but rounds
    -- to whole copper; FlipQueue carries soldPrice off the AH itself.
    copper = { "tsm", "tally-native", "journalator", "flipqueue" },
    -- itemID: Native resolves from the inbox item link; FlipQueue knows
    -- it from the posting; Journalator parses an itemLink; TSM has only
    -- an itemString and we resolve numerically with no metadata.
    itemID = { "tally-native", "flipqueue", "journalator", "tsm" },
    -- count + charKey: any source equally reliable; default order.
    count   = DEFAULT_PRIORITY,
    charKey = DEFAULT_PRIORITY,
  },
  purchase = {
    atTime  = { "tally-native", "journalator", "tsm", "flipqueue" },
    copper  = { "tsm", "tally-native", "journalator", "flipqueue" },
    itemID  = { "tally-native", "flipqueue", "journalator", "tsm" },
    count   = DEFAULT_PRIORITY,
    charKey = DEFAULT_PRIORITY,
  },
  ["ah-cancel"] = {
    -- Native AHPosting fires on AUCTION_HOUSE_AUCTION_CANCELED — exact;
    -- FlipQueue uses postedAt (off by the listing duration); TSM writes
    -- the source-event time but with the usual lag.
    atTime = { "tally-native", "journalator", "tsm", "flipqueue" },
    -- copper is structurally 0 for cancels; Schema doesn't carry money
    -- on this kind. Listed for completeness.
    copper = DEFAULT_PRIORITY,
  },
  ["ah-expire"] = {
    atTime = { "tally-native", "journalator", "tsm", "flipqueue" },
    copper = DEFAULT_PRIORITY,
  },
  ["ah-deposit"] = {
    -- Native AHPosting captures at the moment of POST; Journalator's
    -- Posting bucket fires from the same hook. Either is exact.
    atTime = { "tally-native", "journalator" },
    copper = { "tally-native", "journalator" },
  },
  ["ah-fee"] = {
    -- Only Native produced this kind historically; entry exists for
    -- forward-compat if Journalator's invoice path ever splits the cut
    -- into a separate row.
    atTime = { "tally-native", "journalator" },
    copper = { "tally-native", "journalator" },
  },
  ["vendor-sell"] = {
    -- Native computes copper from sellPrice * count at MERCHANT_CLOSED —
    -- bag delta drives the count exactly. TSM and Journalator write the
    -- vendor txn after the fact.
    atTime  = { "tally-native", "journalator", "tsm" },
    copper  = { "tally-native", "tsm", "journalator" },
    count   = { "tally-native", "tsm", "journalator" },
  },
  ["vendor-buy"] = {
    atTime  = { "tally-native", "journalator", "tsm" },
    copper  = { "tally-native", "tsm", "journalator" },
    count   = { "tally-native", "tsm", "journalator" },
  },
  ["mail-receive"] = {
    atTime = { "tally-native", "journalator" },
    copper = { "tally-native", "journalator" },
  },
  ["mail-send"] = {
    atTime = { "tally-native", "journalator" },
    copper = { "tally-native", "journalator" },
  },
  repair = {
    -- Native's RepairAllItems hook gives the exact money delta;
    -- Journalator's VendorRepairs row is fed from the same UI but
    -- the lag is non-zero.
    atTime = { "tally-native", "journalator" },
    copper = { "tally-native", "journalator" },
  },
  -- trade, taxi, trainer, quest-reward, loot, mission, trading-post,
  -- crafting-order-* are single-source today (Journalator only). They
  -- pass through the merge as 1-row clusters with trivial provenance.
}

-- Returns the priority list for (kind, field), or DEFAULT_PRIORITY if
-- the (kind, field) tuple has no explicit override.
function Ledger:GetAuthority(kind, field)
  local k = Ledger.Authority[kind]
  if k and k[field] then return k[field] end
  return DEFAULT_PRIORITY
end

-- ============================================================================
-- Source registry
-- ============================================================================
--
-- Adapters register here at PLAYER_LOGIN. The spine's ParseCache walks
-- GetSources() and parses each available source's getEntriesFn once per
-- session. This is the only data path in the projection-layer architecture.

local sources = {}     -- name → { name, label, getEntriesFn, isAvailableFn }
local sourceOrder = {}

-- Register an adapter. opts:
--   label         — UI display name (default: name)
--   getEntriesFn  — function() returning (entries[], skippedAtParse). The
--                   pure parse path the spine's ParseCache consumes; must
--                   have no side effects (no ledger writes).
--   isAvailable   — function() returning true if the source can be parsed
--                   now (e.g., the underlying addon is loaded with data).
--                   Optional.
function Ledger:RegisterSource(name, opts)
  if type(name) ~= "string" or name == "" then return end
  opts = opts or {}
  if not sources[name] then
    sourceOrder[#sourceOrder + 1] = name
  end
  sources[name] = {
    name = name,
    label = opts.label or name,
    getEntriesFn = opts.getEntriesFn,
    isAvailableFn = opts.isAvailable,
  }
end

function Ledger:GetSources()
  local out = {}
  for _, n in ipairs(sourceOrder) do out[#out + 1] = sources[n] end
  return out
end

function Ledger:IsSourceAvailable(name)
  local s = sources[name]
  if not s then return false end
  -- User-level opt-out (set by the setup wizard or Settings panel) wins
  -- over runtime detection: even if TSM is loaded, a user who unchecked
  -- it in the wizard expects no rows to flow in.
  if TallyDB and TallyDB.disabledSources and TallyDB.disabledSources[name] then
    return false
  end
  if not s.isAvailableFn then return true end
  local ok, available = pcall(s.isAvailableFn)
  return ok and available or false
end

-- User-level enablement. The runtime availability check (sibling addon
-- loaded?) stays separate; this is the user's preference.
function Ledger:SetSourceEnabled(name, enabled)
  TallyDB.disabledSources = TallyDB.disabledSources or {}
  if enabled then
    TallyDB.disabledSources[name] = nil
  else
    TallyDB.disabledSources[name] = true
  end
end

function Ledger:IsSourceEnabled(name)
  if TallyDB and TallyDB.disabledSources and TallyDB.disabledSources[name] then
    return false
  end
  return true
end

-- ============================================================================
-- Projection shims
-- ============================================================================
--
-- The legacy read API. Tally stores no ledger, so these delegate to the
-- spine's UnifiedLedger (recompute-on-parse). Kept so the Cogworks public
-- API (QueryLedger / LedgerStats) and Research (Reconcile) keep working at
-- their existing call sites without change. All return empty until the
-- parse cache is populated (lazy, on first view open).

-- Filtered unified-ledger read. `filter` accepts the UnifiedLedger filter
-- shape (kind, kinds, itemID, itemKey, charKey, source, realmKey,
-- realmSide, atTimeFrom, atTimeTo, review).
function Ledger:Query(filter)
  local UL = ns.Spine and ns.Spine.UnifiedLedger
  if not (UL and UL.Query) then return {} end
  return UL:Query(filter or {})
end

-- Reconcile was the old multi-source merge pass; the spine's UnifiedLedger
-- is its successor and already returns merged records, so Reconcile is now
-- an alias for Query.
function Ledger:Reconcile(filter)
  return self:Query(filter)
end

function Ledger:Stats(filter)
  local UL = ns.Spine and ns.Spine.UnifiedLedger
  if not (UL and UL.Stats) then
    return { count = 0, review = 0, sources = {}, byRealm = {} }
  end
  return UL:Stats(filter or {})
end

-- ============================================================================
-- Setup gate + reset
-- ============================================================================

-- Whether the first-run wizard has completed. Gates UI affordances that
-- assume the user has chosen sources / strategy.
function Ledger:IsSetupComplete()
  return TallyDB and TallyDB.setup and TallyDB.setup.completed and true or false
end

-- Reset hook for /tally reset. The projection layer stores no ledger, so
-- this just drops any pre-redesign in-memory/on-disk remnant if an old
-- TallyDB.ledger blob is still present.
function Ledger:Clear()
  if TallyDB then TallyDB.ledger = nil end
end
