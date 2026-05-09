-- Tally — Ledger.lua
--
-- Canonical, source-agnostic transaction ledger. Tally writes to its own
-- ledger from day one — sibling addons (FlipQueue, TSM Accounting,
-- Auctionator, etc.) are *sources*, not dependencies. Each source produces
-- entries via a registered adapter; Tally's own Native source hooks WoW
-- events directly. Ledger reads are filtered queries over the pooled
-- entries; cross-source dedupe lives at the entry-id layer.
--
-- Entry shape:
--   {
--     id        = "<source>:<sourceId>",   -- unique per real-world record
--                                           -- as known by the source
--     atTime    = epoch,                   -- when the txn happened
--     kind      = "sale" | "purchase" | "ah-cancel" | "ah-expire"
--                 | "vendor-sell" | "vendor-buy" | "mail-receive"
--                 | "mail-send" | "trade" | "repair" | "ah-fee" | "refund",
--     itemKey   = "12345;bonus;mods",      -- canonical key (or nil for
--                                           -- non-item entries like gold-only)
--     itemID    = 12345,                   -- numeric for fast lookup
--     charKey   = "Hugemane-Stormrage",    -- per-character; "Warband" is
--                                           -- a synthetic charKey for
--                                           -- warband-bank events
--     copper    = 50000,                   -- gross amount in copper
--     count     = 1,                       -- quantity transacted
--     source    = "flipqueue",             -- adapter name
--     sourceId  = "abc123",                -- stable identifier within source
--     meta      = { ... },                 -- source-specific extras
--   }
--
-- Storage:
--   TallyDB.ledger = {
--     entries = { ... sorted ascending by atTime ... },
--     byId    = { ["<source>:<sourceId>"] = true },
--   }
--
-- Cross-source dedupe (same real-world event reported by Native + an adapter)
-- is intentionally *not* automated at insert time. Entries from multiple
-- sources for the same event coexist with distinct ids; future work can add
-- view-time consolidation. For now `source` is surfaced in the UI so users
-- understand provenance.

local addonName, ns = ...

local Ledger = {}
ns.Ledger = Ledger

-- Canonical kind enum exposed for adapters and UI filters.
--
-- Phase-1 kinds (Native + TSM + FlipQueue): sale, purchase, ah-cancel,
-- ah-expire, ah-fee, vendor-sell, vendor-buy, mail-receive, mail-send,
-- trade, repair, refund.
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
-- introspection surface for /tally diag + the future Reconcile pass
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
  -- in-flight active status" by inspection. KindSign returns 0 so these
  -- never affect income/expense totals.
  unknown = {
    canonical = { "source", "sourceId" },
    sourceFields = {},
    metaRequired = { "sourceKind" },
  },
}

-- Returns the schema entry for a kind (canonical + sourceFields) or nil
-- if the kind is unrecognized. Used by /tally diag introspection and by
-- the future Reconcile pass to decide which fields a given source can
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
-- Authority + Reconcile (TLY-30)
-- ============================================================================
--
-- Authority: per-(kind, field) source priority. When two or more adapters
-- captured the same real-world event, Reconcile merges them into one
-- record by picking each canonical field from the highest-priority source
-- that has a non-nil value for it. The selection is per-field, not per-
-- row, so a single reconciled record can have atTime from Native (event-
-- driven, exact second) and copper from TSM (knows the AH cut precisely).
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
    -- Only Native produces this kind currently; entry exists for
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
  -- will pass through Reconcile as 1-row clusters with trivial provenance;
  -- when Native picks up these kinds we'll add explicit Authority entries.
}

-- Returns the priority list for (kind, field), or DEFAULT_PRIORITY if
-- the (kind, field) tuple has no explicit override.
function Ledger:GetAuthority(kind, field)
  local k = Ledger.Authority[kind]
  if k and k[field] then return k[field] end
  return DEFAULT_PRIORITY
end

-- Reconcile clustering windows. Same-event captures across sources land
-- within seconds for live capture (Native + Journalator) but TSM's CSV
-- write lag can be longer; the loose window catches the wider spread
-- without coalescing distinct postings of the same item.
--
-- Stricter than Compare's tiered matching: Compare's "fuzzy" tier (1h)
-- exists to align bulk archive imports between sources whose clocks may
-- have drifted; Reconcile is reasoning about live multi-source overlap
-- on a single user's events, where 5min covers all observed lag.
local RECONCILE_WINDOW = 5 * 60  -- 5 minutes

-- Field list reconciled per record. Universal id/atTime/kind/source are
-- handled inline (kind / charKey / itemID drive the grouping; id is
-- regenerated for the reconciled record).
local RECONCILED_FIELDS = { "atTime", "copper", "count", "itemKey" }

-- For one cluster (set of rows representing the same real-world event),
-- pick each canonical field from the highest-priority source with a
-- non-nil value, falling back to the first row's value. Returns the
-- merged record + provenance map.
local function buildReconciledRecord(cluster, kind, charKey, itemID)
  -- Single-row cluster: trivial pass-through, provenance points entirely
  -- at the one source.
  if #cluster == 1 then
    local e = cluster[1]
    return {
      id          = "reconciled:" .. (e.id or "?"),
      atTime      = e.atTime,
      kind        = kind,
      itemID      = itemID,
      itemKey     = e.itemKey,
      charKey     = charKey,
      copper      = e.copper,
      count       = e.count,
      meta        = e.meta,
      -- Representative source: same as the only contributor for 1-row
      -- clusters. Preserves the field for consumers that read it directly
      -- (Research/Aggregator) without forcing them onto provenance.
      source      = e.source,
      sources     = { [e.source or "?"] = true },
      originalIds = { e.id },
      provenance  = {
        atTime = e.source, copper = e.source, count = e.source,
        itemKey = e.source, meta = e.source,
      },
    }
  end

  local rec = {
    kind        = kind,
    itemID      = itemID,
    charKey     = charKey,
    sources     = {},
    originalIds = {},
    provenance  = {},
  }
  for _, e in ipairs(cluster) do
    rec.sources[e.source or "?"] = true
    rec.originalIds[#rec.originalIds + 1] = e.id
  end

  -- Synthetic id for reconciled record. Stable across re-imports as
  -- long as the underlying originalIds are stable (they are — adapters
  -- hash on canonical row identity).
  rec.id = "reconciled:" .. table.concat(rec.originalIds, "+")

  for _, field in ipairs(RECONCILED_FIELDS) do
    local priority = Ledger.Authority[kind] and Ledger.Authority[kind][field]
                  or DEFAULT_PRIORITY
    local picked, pickedFrom = nil, nil
    for _, srcName in ipairs(priority) do
      for _, e in ipairs(cluster) do
        if e.source == srcName and e[field] ~= nil then
          picked = e[field]
          pickedFrom = srcName
          break
        end
      end
      if pickedFrom then break end
    end
    -- Fallback: any row's non-nil value, in cluster order.
    if pickedFrom == nil then
      for _, e in ipairs(cluster) do
        if e[field] ~= nil then
          picked = e[field]
          pickedFrom = e.source
          break
        end
      end
    end
    rec[field] = picked
    rec.provenance[field] = pickedFrom
  end

  -- Meta: shallow merge across rows. Higher-priority sources' meta keys
  -- win; lower-priority keys fill in gaps. Provenance points at whichever
  -- source contributed the *first* observed key for each meta field.
  -- Coarser than per-meta-key provenance, sufficient for current consumers.
  rec.meta = {}
  rec.metaProvenance = {}
  local priority = Ledger.Authority[kind] and Ledger.Authority[kind].atTime
                or DEFAULT_PRIORITY
  -- Walk in priority order so higher-priority rows write first; the
  -- second-pass over remaining rows fills in keys the leader didn't have.
  local visited = {}
  for _, srcName in ipairs(priority) do
    for _, e in ipairs(cluster) do
      if e.source == srcName and not visited[e] and type(e.meta) == "table" then
        visited[e] = true
        for k, v in pairs(e.meta) do
          if rec.meta[k] == nil then
            rec.meta[k] = v
            rec.metaProvenance[k] = e.source
          end
        end
      end
    end
  end
  for _, e in ipairs(cluster) do
    if not visited[e] and type(e.meta) == "table" then
      for k, v in pairs(e.meta) do
        if rec.meta[k] == nil then
          rec.meta[k] = v
          rec.metaProvenance[k] = e.source
        end
      end
    end
  end
  rec.provenance.meta = next(rec.metaProvenance)
                        and rec.metaProvenance[next(rec.metaProvenance)]
                        or (cluster[1] and cluster[1].source)

  -- Representative source: whichever source won the atTime priority.
  -- This is the "primary observer" — not the only source (cluster has
  -- multiple), but the one consumers should treat as the canonical one
  -- when they need a single string. Aggregator and similar reads `e.source`
  -- directly; preserving the field keeps those callers source-agnostic.
  rec.source = rec.provenance.atTime or (cluster[1] and cluster[1].source)

  return rec
end

-- Cluster a sorted-by-atTime list of rows (all sharing the same kind +
-- charKey + itemID) into groups representing same-real-world-event
-- captures. Greedy: each row joins the first prior cluster within
-- RECONCILE_WINDOW that has matching count *and* doesn't already include
-- a row from the candidate's source; otherwise opens a new cluster.
--
-- The source-uniqueness gate (TLY-48) keeps Reconcile aligned with its
-- intended job — coalescing cross-source observations of one event —
-- without papering over distinct same-source events that happen to share
-- shape inside the window. Each adapter is the authoritative deduper for
-- its own rows (TSM/FlipQueue/Journalator/Native each hash on canonical
-- row identity at insert time), so by the time two same-source rows
-- reach the ledger they represent two distinct events from that source's
-- perspective. Pre-fix `clusterGroup` was source-blind and collapsed
-- vendor-flurries / back-to-back postings of the same item into one
-- record, which dropped one row's copper via the Authority pick.
local function clusterGroup(rows)
  local clusters = {}
  local clusterSources = {}
  for _, e in ipairs(rows) do
    local matched
    local src = e.source or "?"
    for i, cluster in ipairs(clusters) do
      local first = cluster[1]
      if (e.count or 1) == (first.count or 1)
         and math.abs((e.atTime or 0) - (first.atTime or 0)) <= RECONCILE_WINDOW
         and not clusterSources[i][src] then
        cluster[#cluster + 1] = e
        clusterSources[i][src] = true
        matched = true
        break
      end
    end
    if not matched then
      clusters[#clusters + 1] = { e }
      clusterSources[#clusters] = { [src] = true }
    end
  end
  return clusters
end

-- Reconcile multi-source observations of the same event into one record
-- per event, with per-field provenance. Same call surface as Query so
-- consumers can swap drop-in.
--
-- Behavior:
--   * filter — same shape as Query (kind, kinds, itemID, itemKey,
--              charKey, source, atTimeFrom, atTimeTo).
--   * Returns a list of reconciled records. Each record carries:
--       id, atTime, kind, itemID, itemKey, charKey, copper, count,
--       meta, sources (set), originalIds (list), provenance (map),
--       metaProvenance (map).
--   * Single-source captures pass through as 1-row clusters — same
--       record shape, sources has one entry, provenance points at it.
--
-- Kinds that don't reconcile:
--   * Ledger.Kinds.Unknown — by definition each Unknown row carries a
--       distinct sourceKind; merging would lose that diagnostic. They
--       pass through as 1-row clusters (provenance.atTime = source).
--
-- Filtering by source via filter.source short-circuits reconciliation
-- (single-source filter → single-row clusters; useful for the LedgerPage
-- Raw-mode filter chips that select a specific adapter).
--
-- Result caching: the Reconcile output for a given filter is cached
-- in-memory and invalidated by any mutation to the active set or
-- archives (Insert / InsertMany / InsertManyChunked / Clear /
-- ClearSource / seal paths). Without this, every UI tab open re-ran
-- the full clustered scan over hundreds of thousands of rows; the
-- cache is the structural fix for the per-tab-open freeze on big
-- ledgers (zpectre 438k, Toeknee Compare hang).
local _reconcileCache = {}

local function reconcileFilterKey(filter)
  if not filter then return "" end
  local keys = {}
  for k in pairs(filter) do keys[#keys + 1] = k end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = filter[k]
    if type(v) == "table" then
      local copy = {}
      for i, item in ipairs(v) do copy[i] = tostring(item) end
      table.sort(copy)
      parts[#parts + 1] = k .. "=[" .. table.concat(copy, ",") .. "]"
    else
      parts[#parts + 1] = k .. "=" .. tostring(v)
    end
  end
  return table.concat(parts, ";")
end

local function invalidateReconcileCache()
  _reconcileCache = {}
end

-- Public hook for callers that mutate active set or archives outside
-- the normal Insert / Clear paths (seal, schema-version rebuild, etc.).
function Ledger:InvalidateReconcileCache()
  invalidateReconcileCache()
end

function Ledger:Reconcile(filter)
  local cacheKey = reconcileFilterKey(filter)
  local cached = _reconcileCache[cacheKey]
  if cached then return cached end

  local rows = self:Query(filter)
  if #rows == 0 then
    _reconcileCache[cacheKey] = {}
    return _reconcileCache[cacheKey]
  end

  -- Group by (kind, charKey, itemID). Rows with nil itemID share the
  -- "0" bucket — fine for kinds that don't carry an item (ah-fee, repair,
  -- taxi, etc.); those still cluster correctly by atTime + count.
  local groups = {}
  local groupOrder = {}
  for _, e in ipairs(rows) do
    local key = (e.kind or "?") .. "|"
             .. (e.charKey or "?") .. "|"
             .. tostring(e.itemID or 0)
    if not groups[key] then
      groups[key] = {}
      groupOrder[#groupOrder + 1] = key
    end
    groups[key][#groups[key] + 1] = e
  end

  local records = {}
  for _, key in ipairs(groupOrder) do
    local group = groups[key]
    table.sort(group, function(a, b) return (a.atTime or 0) < (b.atTime or 0) end)
    local kind    = group[1].kind
    local charKey = group[1].charKey
    local itemID  = group[1].itemID
    local clusters = clusterGroup(group)
    for _, cluster in ipairs(clusters) do
      records[#records + 1] = buildReconciledRecord(cluster, kind, charKey, itemID)
    end
  end

  _reconcileCache[cacheKey] = records
  return records
end

-- ============================================================================
-- Session-window log (TLY-45)
-- ============================================================================
--
-- Records when Tally itself was loaded and observing events. The native
-- source is event-driven — it only captures what fires while Tally is
-- running, so divergence between Native and a sibling adapter at a
-- given timestamp could mean either "Tally has a capture bug" or
-- "Tally wasn't loaded then." The session log distinguishes those two
-- cases so DivergenceReport can categorize gaps as real (Tally was
-- running, should have captured) vs expected (Tally wasn't running,
-- sibling backfill is the only ground truth).
--
-- Storage:
--   TallyDB.sessions = {
--     { startedAt, lastSeenAt, build, version, charKey }, ...
--   }
--
-- Bounded ring of MAX_SESSIONS entries so the table doesn't grow
-- unbounded across years of play. 200 covers ~6-12 months of typical
-- daily play; lookups walk in reverse (most recent first) so the LRU
-- truncation doesn't hurt query latency.

local MAX_SESSIONS = 200

local function sessionsList()
  TallyDB = TallyDB or {}
  TallyDB.sessions = TallyDB.sessions or {}
  return TallyDB.sessions
end

-- Open a new session entry. Called once per PLAYER_LOGIN (Core.lua).
-- charKey identifies which character's login produced this session —
-- useful for cross-checks but not load-bearing for divergence math.
function Ledger:StartSession(opts)
  opts = opts or {}
  local sessions = sessionsList()
  local now = (opts.atTime ~= nil) and opts.atTime or time()
  sessions[#sessions + 1] = {
    startedAt  = now,
    lastSeenAt = now,
    build      = opts.build,
    version    = opts.version,
    charKey    = opts.charKey,
  }
  -- Bounded ring: drop oldest if we exceeded the cap.
  while #sessions > MAX_SESSIONS do
    table.remove(sessions, 1)
  end
end

-- Update the most recent session's lastSeenAt. Called periodically by
-- the heartbeat ticker. No-op if no session has been started yet
-- (defensive — the heartbeat shouldn't fire pre-login but the addon
-- can run /reload mid-session and the ticker may resume before
-- StartSession does in some race orders).
function Ledger:HeartbeatSession(opts)
  opts = opts or {}
  local sessions = sessionsList()
  local current = sessions[#sessions]
  if not current then return end
  local now = (opts.atTime ~= nil) and opts.atTime or time()
  current.lastSeenAt = math.max(current.lastSeenAt or 0, now)
end

-- Returns the session entry whose [startedAt, lastSeenAt + grace]
-- window covers `t`, or nil if no session does. Walks in reverse so
-- recent queries are O(1) amortized.
--
-- Grace window absorbs the period between the last heartbeat and any
-- terminating event — without it, a row captured 30s after the last
-- heartbeat fall outside the session and erroneously look like an
-- "expected gap." 90s = 60s heartbeat interval + 30s slack.
local SESSION_GRACE = 90

function Ledger:SessionForTime(t)
  if type(t) ~= "number" or t <= 0 then return nil end
  local sessions = sessionsList()
  for i = #sessions, 1, -1 do
    local s = sessions[i]
    if s.startedAt and t >= s.startedAt
       and t <= (s.lastSeenAt or s.startedAt) + SESSION_GRACE then
      return s
    end
  end
  return nil
end

-- Returns the count of sessions in the log + the count whose
-- [startedAt, lastSeenAt] window overlaps the [from, to] range.
-- Used by DivergenceReport for the "Tally was running for X% of the
-- analyzed window" header line.
function Ledger:SessionCoverage(from, to)
  local sessions = sessionsList()
  local total = #sessions
  if not (from and to) or from > to then return total, 0, 0 end
  local overlapping = 0
  local coveredSec = 0
  for _, s in ipairs(sessions) do
    local sStart = s.startedAt or 0
    local sEnd = (s.lastSeenAt or s.startedAt or 0) + SESSION_GRACE
    if sEnd >= from and sStart <= to then
      overlapping = overlapping + 1
      local lo = math.max(sStart, from)
      local hi = math.min(sEnd, to)
      if hi > lo then coveredSec = coveredSec + (hi - lo) end
    end
  end
  return total, overlapping, coveredSec
end

-- ============================================================================
-- Divergence reporter (TLY-45)
-- ============================================================================
--
-- Periodic + on-demand diagnostic. Categorizes source-disagreements
-- across the ledger:
--
--   * field-disagreement — every relevant source captured the event,
--                          but disagree on copper / atTime / etc.
--                          Reconcile already picks; reporter just
--                          counts so we know how often it happens.
--   * real-gap          — a sibling has the event, Native doesn't,
--                          but the event's atTime falls inside a
--                          session window where Tally was running.
--                          This is the bug class we care about — Tally
--                          should have observed it but didn't.
--   * expected-gap      — a sibling has the event, Native doesn't,
--                          atTime outside any session window. Catalog
--                          but don't alarm — this is what backfill is
--                          for.
--
-- Returns a structured report consumed by /tally diag divergence and
-- by the periodic ticker (Phase 4) to surface real-gap counts to chat
-- (or the LDB tooltip, when one exists).

local NATIVE_SOURCE_NAME = "tally-native"

-- A "covered by Native" event is one where any cluster member has
-- source = "tally-native". If Native covered the cluster, we don't
-- need to second-guess sibling-only observations.
local function clusterHasNative(cluster)
  for _, e in ipairs(cluster) do
    if e.source == NATIVE_SOURCE_NAME then return true end
  end
  return false
end

-- A field-disagreement exists when at least two cluster members
-- carry distinct values for the same canonical field. Returns a
-- list of fields that disagree; empty list means the cluster is
-- structurally consistent across sources.
local function fieldDisagreements(cluster)
  local fields = { "atTime", "copper", "count", "itemKey" }
  local out = {}
  for _, field in ipairs(fields) do
    local seen
    for _, e in ipairs(cluster) do
      local v = e[field]
      if v ~= nil then
        if seen == nil then
          seen = v
        elseif seen ~= v then
          out[#out + 1] = field
          break
        end
      end
    end
  end
  return out
end

function Ledger:DivergenceReport(filter)
  filter = filter or {}
  local rows = self:Query(filter)

  -- Reuse the Reconcile clustering pipeline — same grouping rules,
  -- different output. We need access to the raw cluster (with all
  -- contributing rows + their sources) rather than the merged record.
  local groups = {}
  local groupOrder = {}
  for _, e in ipairs(rows) do
    -- Skip Unknown rows — by definition they don't reconcile (each
    -- carries a distinct sourceKind), so divergence math doesn't apply.
    if e.kind ~= Ledger.Kinds.Unknown then
      local key = (e.kind or "?") .. "|"
               .. (e.charKey or "?") .. "|"
               .. tostring(e.itemID or 0)
      if not groups[key] then
        groups[key] = {}
        groupOrder[#groupOrder + 1] = key
      end
      groups[key][#groups[key] + 1] = e
    end
  end

  local report = {
    fieldDisagreement = {},  -- list of { cluster, fields[] }
    realGap           = {},  -- list of { cluster, sessionRef }
    expectedGap       = {},  -- list of { cluster }
    summary           = {
      clusters             = 0,
      multiSourceClusters  = 0,
      fieldDisagreementCount = 0,
      realGapCount         = 0,
      expectedGapCount     = 0,
      sourceCounts         = {},  -- { [source] = N rows seen }
    },
  }

  for _, key in ipairs(groupOrder) do
    local group = groups[key]
    table.sort(group, function(a, b) return (a.atTime or 0) < (b.atTime or 0) end)
    local clusters = clusterGroup(group)
    for _, cluster in ipairs(clusters) do
      report.summary.clusters = report.summary.clusters + 1

      -- Source counts (every row contributes to its source's tally so
      -- the diag header can show "TSM contributed 4327 rows, Native
      -- contributed 891" etc.).
      for _, e in ipairs(cluster) do
        local s = e.source or "?"
        report.summary.sourceCounts[s] = (report.summary.sourceCounts[s] or 0) + 1
      end

      if #cluster > 1 then
        report.summary.multiSourceClusters = report.summary.multiSourceClusters + 1

        local fd = fieldDisagreements(cluster)
        if #fd > 0 then
          report.fieldDisagreement[#report.fieldDisagreement + 1] = {
            cluster = cluster,
            fields  = fd,
          }
          report.summary.fieldDisagreementCount = report.summary.fieldDisagreementCount + 1
        end
      end

      -- Gap analysis: if cluster has no Native row, it's a sibling-only
      -- observation. Categorize by whether Tally was running at that
      -- time. Gap is recorded against the cluster's anchor atTime
      -- (first row chronologically); SessionForTime decides.
      if not clusterHasNative(cluster) then
        local anchor = cluster[1]
        local session = self:SessionForTime(anchor.atTime or 0)
        if session then
          report.realGap[#report.realGap + 1] = {
            cluster    = cluster,
            sessionRef = session,
          }
          report.summary.realGapCount = report.summary.realGapCount + 1
        else
          report.expectedGap[#report.expectedGap + 1] = { cluster = cluster }
          report.summary.expectedGapCount = report.summary.expectedGapCount + 1
        end
      end
    end
  end

  return report
end

-- ============================================================================
-- Storage (TLY-49 compressed blob, TLY-51 tiered active + archives)
-- ============================================================================
--
-- On disk (TallyDB.ledger):
--   active       = <serialised+deflated blob>          -- mutable hot path
--   activeMeta   = { count, savedAt, bytes, serialiseMs, compressMs, ... }
--   archives     = { ["YYYY-MM"|"YYYY-MM-wN"] = { blob, count, fromTs, toTs, bytes, schemaVer, savedAt } }
--   archiveIndex = { ["YYYY-MM"|"YYYY-MM-wN"] = { itemIDs, charKeys, kindCounts, monthlyAggregates, ... } }
--
-- The active set is the only mutable structure. Archives are write-once
-- at seal time (Archive.lua) and lazy-loaded into Archive's LRU(3) cache
-- when a query expands beyond the default `filter.window = "active"`.
-- archiveIndex stays resident permanently — it's tiny relative to the
-- archive blobs and lets the query layer skip whole archives without
-- touching the compressed payload.
--
-- In memory: _workingMem holds the deserialised active { entries, byId }.
-- Lazy loaded on first db() call; reserialised on PLAYER_LOGOUT (or any
-- explicit Ledger:SaveToDisk()).
--
-- Dirty tracking: Insert / InsertMany / Clear / ClearSource / seal flip
-- _dirty. SaveToDisk early-exits if not dirty so logout doesn't pay the
-- serialise cost on read-only sessions. Archives are never dirty after
-- their initial seal write — re-saving an archive happens explicitly via
-- Archive:Save() during seal or ClearSource cleanup.
--
-- Migration paths handled in loadFromDisk:
--   1. Modern shape (TallyDB.ledger.active blob present): deserialise into
--      _workingMem.active. _dirty = false.
--   2. alpha14/15 single-blob (TallyDB.ledger.blob): deserialise the
--      legacy blob, promote into _workingMem.active, mark dirty so the
--      next save lands the new shape. Legacy blob retained on disk until
--      the first successful new-shape save (belt-and-suspenders, same
--      pattern TLY-49 used).
--   3. Pre-alpha14 raw entries (TallyDB.ledger.entries): same handling as
--      legacy blob — promote into active and mark dirty.
--
-- Phase 1 (alpha16) loads everything into the active set even if it's
-- 438k rows. The route-by-date migration that splits a legacy blob into
-- active + archives is a separate Phase 1 task (TLY-51 #8); this commit
-- is the storage-shape change only. Until that lands, alpha14/15 users
-- get the new shape but with a fat active set.

local LibSerialize = LibStub and LibStub("LibSerialize", true)
local LibDeflate   = LibStub and LibStub("LibDeflate", true)

-- Bumped when active+archive entry shape changes incompatibly. Mirrors
-- Archive.SCHEMA_VERSION; Archive blobs are tagged with the same value.
Ledger.SCHEMA_VERSION = 1

local _workingMem  -- { active = { entries = {...}, byId = {...} } }
local _loaded = false
local _dirty = false

local function defaultMem()
  return { active = { entries = {}, byId = {} } }
end

local function loadFromDisk()
  TallyDB = TallyDB or {}
  TallyDB.ledger = TallyDB.ledger or {}
  local L = TallyDB.ledger

  if not (LibSerialize and LibDeflate) then
    _workingMem = defaultMem()
    _loaded = true
    _dirty = false
    return
  end

  -- Modern (TLY-51) path: tiered active + archives.
  if L.active then
    local decompressed = LibDeflate:DecompressDeflate(L.active)
    if decompressed then
      local ok, payload = LibSerialize:Deserialize(decompressed)
      if ok and type(payload) == "table" then
        _workingMem = {
          active = {
            entries = payload.entries or {},
            byId    = payload.byId or {},
          },
        }
        _loaded = true
        _dirty = false
        -- Legacy archives (TallyDB.ledger.archives[key].blob from prior
        -- alpha16-candidate builds before the multi-SV switch) migrate
        -- lazily to slots on first Archive:Load(key). Most operations
        -- that touch archives (ClearSourceAsync's Delete fast-path,
        -- gatherRows' GetIndex skip-test) avoid the load entirely when
        -- archiveIndex carries sourceCounts. Eager migration would
        -- freeze login by ~150-300ms per archive on the way in.
        return
      end
    end
    print("|cffff8080Tally:|r ledger active set failed to load — starting fresh. Run /tally setup to backfill from sibling sources.")
    _workingMem = defaultMem()
    _loaded = true
    _dirty = false
    return
  end

  -- Migration 1: alpha14/15 single-blob. The full deserialise of a
  -- 200k+ row legacy blob takes 30-50s synchronously — unacceptable
  -- as a login freeze. Stash the compressed bytes in pendingLegacy
  -- and return immediately; PLAYER_LOGIN's deferred handler will call
  -- Ledger:KickLegacyLoad to async-deserialise across ticks (chunked
  -- via LibSerialize:DeserializeAsync with a 1024-item yieldCheck).
  -- Active stays empty during the load window; Count() reads the
  -- legacy blob's metadata count so the grandfather check still
  -- recognises the user as already-onboarded.
  if L.blob then
    _workingMem = {
      active = { entries = {}, byId = {} },
      pendingLegacy = {
        blob = L.blob,
        meta = L.blobMeta or {},
      },
    }
    _loaded = true
    _dirty = false
    return
  end

  -- Migration 2: pre-alpha14 raw entries — same pending-migration path.
  if L.entries then
    _workingMem = {
      active = { entries = {}, byId = {} },
      pendingMigration = {
        entries = L.entries,
        byId    = L.byId or {},
      },
    }
    _loaded = true
    _dirty = false
    return
  end

  _workingMem = defaultMem()
  _loaded = true
  _dirty = false
end

local function db()
  if not _loaded then loadFromDisk() end
  return _workingMem.active
end

-- Public: serialise + compress _workingMem.active and write to
-- TallyDB.ledger.active. Called from Core.lua's PLAYER_LOGOUT handler.
-- No-op when nothing dirty so read-only sessions don't pay the cost.
--
-- Compression level (TLY-50): LibDeflate at level 1, the fastest setting.
-- Once tiering ships (TLY-51) the active set is bounded ≤25k rows so
-- compression cost is well within fast-compress territory at any level;
-- level 1 gives the most headroom for future scale.
--
-- Archives are never re-saved by this function — they're write-once at
-- seal time via Archive:Save(). The active blob is the only thing that
-- gets refreshed on every logout cycle.
function Ledger:SaveToDisk()
  if not _loaded then return end
  if not _dirty then return end
  if not (LibSerialize and LibDeflate) then return end

  -- Mid-migration / mid-load: don't save active and don't clear the
  -- legacy blob. If we persisted active alongside legacy here, a
  -- subsequent reload would see both and SaveToDisk's
  -- migration-completion clear would wipe the legacy blob. Skipping
  -- the save means a logout during the legacy load or migration
  -- restarts cleanly from the legacy blob on next session, losing
  -- only any native events captured in the partial active during
  -- this session (small window, typically minutes).
  if _workingMem.pendingLegacy then return end
  if _workingMem.pendingMigration then return end

  local startMs = (debugprofilestop and debugprofilestop()) or 0

  local active = _workingMem.active
  local payload    = { entries = active.entries, byId = active.byId }
  local serialised = LibSerialize:Serialize(payload)
  local serialisedMs = (debugprofilestop and debugprofilestop()) or 0
  local compressed = LibDeflate:CompressDeflate(serialised, { level = 1 })
  local compressedMs = (debugprofilestop and debugprofilestop()) or 0

  TallyDB = TallyDB or {}
  TallyDB.ledger = TallyDB.ledger or {}
  TallyDB.ledger.active = compressed
  TallyDB.ledger.activeMeta = {
    count             = #active.entries,
    savedAt           = time(),
    bytes             = #compressed,
    serialisedBytes   = #serialised,
    serialiseMs       = math.floor(serialisedMs - startMs),
    compressMs        = math.floor(compressedMs - serialisedMs),
    schemaVer         = self.SCHEMA_VERSION,
  }
  -- Migration completion: clear legacy fields once the new-shape save
  -- lands. From here on WoW persists active + activeMeta + archives only.
  TallyDB.ledger.blob = nil
  TallyDB.ledger.blobMeta = nil
  TallyDB.ledger.entries = nil
  TallyDB.ledger.byId    = nil

  _dirty = false
end

-- Diagnostic surface: returns the post-load active meta + archive count
-- + cache state so /tally diag Storage section can show what storage
-- looks like.
function Ledger:StorageInfo()
  if not _loaded then loadFromDisk() end
  TallyDB = TallyDB or {}
  local L = TallyDB.ledger or {}
  local meta = L.activeMeta or L.blobMeta or nil
  local activeRows = (_workingMem and _workingMem.active and #_workingMem.active.entries) or 0

  -- Archive metrics now come from the multi-SV slot allocator. Slot-
  -- based archives don't carry a per-archive byte count (they're raw
  -- tables, not a serialised blob); legacy single-blob archives still
  -- on disk pre-migration carry rec.bytes via Archive:GetMeta.
  local archiveCount, archiveBytes, archiveRows = 0, 0, 0
  if ns.Archive and ns.Archive.List then
    for _, key in ipairs(ns.Archive:List()) do
      local m = ns.Archive:GetIndex(key) or ns.Archive:GetMeta(key) or {}
      archiveCount = archiveCount + 1
      archiveBytes = archiveBytes + (m.bytes or 0)
      archiveRows  = archiveRows + (m.count or 0)
    end
  end

  local cachedKeys, cacheCap = {}, 0
  if ns.Archive then
    cachedKeys = ns.Archive:CachedKeys()
    cacheCap   = ns.Archive:CacheCap()
  end

  local pendingRows = (_workingMem and _workingMem.pendingMigration
                       and #_workingMem.pendingMigration.entries) or 0
  local pendingLegacy = _workingMem and _workingMem.pendingLegacy
  local pendingLegacyRows = (pendingLegacy and pendingLegacy.meta and pendingLegacy.meta.count) or 0
  local pendingLegacyBytes = (pendingLegacy and pendingLegacy.blob and #pendingLegacy.blob) or 0

  local stagingKeys = self:GetStagingKeys()
  local stagingRows = self:GetStagingRowCount()

  return {
    libsAvailable    = (LibSerialize and LibDeflate) and true or false,
    loaded           = _loaded,
    dirty            = _dirty,
    schemaVer        = self.SCHEMA_VERSION,
    inMemoryCount    = activeRows,
    activeRows       = activeRows,
    activeBytes      = meta and meta.bytes or 0,
    activeSavedAt    = meta and meta.savedAt or nil,
    serialisedBytes  = meta and meta.serialisedBytes or 0,
    serialiseMs      = meta and meta.serialiseMs or 0,
    compressMs       = meta and meta.compressMs or 0,
    archiveCount     = archiveCount,
    archiveBytes     = archiveBytes,
    archiveRows      = archiveRows,
    totalRows        = activeRows + archiveRows,
    cachedArchives   = cachedKeys,
    cacheCap         = cacheCap,
    pendingMigration   = pendingRows > 0,
    pendingRows        = pendingRows,
    pendingLegacyLoad  = pendingLegacy ~= nil,
    pendingLegacyRows  = pendingLegacyRows,
    pendingLegacyBytes = pendingLegacyBytes,
    stagingKeys        = stagingKeys,
    stagingRows        = stagingRows,
    -- Back-compat aliases for callers still using the pre-TLY-51 names:
    blobBytes        = meta and meta.bytes or 0,
    blobCount        = meta and meta.count or 0,
    blobSavedAt      = meta and meta.savedAt or nil,
    legacyPresent    = (L.entries or L.blob) and true or false,
  }
end

-- ============================================================================
-- Migration (TLY-51): legacy single-blob → tiered active + archives
-- ============================================================================
--
-- alpha14/15 single-blob users land in loadFromDisk with their entries
-- in `_workingMem.pendingMigration` instead of active. The migration
-- pass walks the buffer in chunks and routes each entry by date —
-- current month → active, prior months → in-memory staging buckets.
-- After all rows are routed the staging buckets are flushed one at a
-- time to Archive:Save. Once everything is on disk in the new shape,
-- the next SaveToDisk clears the legacy blob.
--
-- Crash safety: SaveToDisk skips writing while a pendingMigration
-- buffer is present, so if the user logs out mid-pass the on-disk
-- state stays "legacy blob, no new active blob, possibly some
-- archives". The legacy blob is the ground truth on next login —
-- the partial archives get overwritten when their months are
-- re-flushed from the re-deserialised legacy blob.
--
-- The chunked walk uses the same C_Timer.After / 50ms slice / 500-row
-- pattern as InsertManyChunked so the input thread stays responsive
-- through the multi-second routing pass on large legacy ledgers.

local _migration = nil  -- in-flight migration state, see StartMigration
local _legacyLoad = nil  -- in-flight legacy-blob async deserialise, see KickLegacyLoad

-- Routed-import staging buckets. Bulk-import paths (the wizard backfill +
-- any other route-by-date insert flow) drop prior-month rows into here
-- keyed on YYYY-MM, then flush at end-of-import via Ledger:FlushStaging.
-- Survives across InsertManyChunkedRouted calls within a single driver
-- run; left empty after a successful flush. Distinct from _migration's
-- own staging — the migration owns its buckets internally because its
-- input is the legacy blob, not a sequence of source-supplied chunks.
local _staging = {}

local function getCurrentMonthStart()
  local t = time()
  local d = date("*t", t)
  return time({ year = d.year, month = d.month, day = 1, hour = 0, min = 0, sec = 0 })
end

-- Migration uses the shared getCurrentMonthStart helper (above) — rows
-- with atTime ≥ that boundary go into active; older rows route to
-- monthly staging buckets keyed on `date("%Y-%m", e.atTime)`.

local migrationStep
migrationStep = function()
  if not _migration then return end
  local m = _migration

  -- Routing phase: pull a chunk from pendingMigration.entries, decide
  -- active vs staging[month] for each, append. When routing finishes,
  -- transfer the migration's internal staging buckets into the module-
  -- private _staging table and hand off to Ledger:FlushStaging — that
  -- way the migration writes go through the same async-serialise +
  -- auto-subdivide flush path the wizard backfill uses.
  local pending = _workingMem.pendingMigration
  if not pending then return end  -- defensive; shouldn't happen with the new control flow

  local active = _workingMem.active
  local stop = math.min(m.idx + m.chunkSize, m.total)
  while m.idx < stop do
    m.idx = m.idx + 1
    local e = pending.entries[m.idx]
    if e and e.id then
      if (e.atTime or 0) >= m.currentMonthStart or not e.atTime then
        if not active.byId[e.id] then
          active.byId[e.id] = true
          active.entries[#active.entries + 1] = e
        end
      else
        local mkey = date("%Y-%m", e.atTime)
        local bucket = m.staging[mkey]
        if not bucket then
          bucket = { entries = {}, byId = {} }
          m.staging[mkey] = bucket
        end
        if not bucket.byId[e.id] then
          bucket.byId[e.id] = true
          bucket.entries[#bucket.entries + 1] = e
        end
      end
    end
  end

  -- Per-chunk cache invalidation so any in-session UI refresh sees the
  -- routed rows.
  invalidateReconcileCache()
  if m.opts.onProgress then
    pcall(m.opts.onProgress, "route", m.idx, m.total)
  end

  if m.idx >= m.total then
    -- Routing done. Drop the pending buffer (all rows are placed now)
    -- and transfer migration's internal staging into module-private
    -- _staging, then hand off to FlushStaging.
    _workingMem.pendingMigration = nil
    for k, bucket in pairs(m.staging) do
      _staging[k] = bucket
    end
    m.staging = {}

    Ledger:FlushStaging({
      delaySec = m.delaySec,
      onProgress = function(flushIdx, flushTotal, key, mergedRowCount)
        if m.opts.onProgress then
          pcall(m.opts.onProgress, "flush", flushIdx, flushTotal, key)
        end
      end,
      onComplete = function(archivesWritten, rowsArchived)
        local activeRows = #_workingMem.active.entries
        local opts = m.opts
        _migration = nil
        _dirty = true
        invalidateReconcileCache()
        if opts.onComplete then
          pcall(opts.onComplete, activeRows, archivesWritten, rowsArchived)
        end
      end,
    })
    return
  end

  if C_Timer and C_Timer.After then
    C_Timer.After(m.delaySec, migrationStep)
  else
    migrationStep()
  end
end

-- True between the loadFromDisk that detected a legacy blob and the
-- final flush of all staging buckets. UI surfaces use this to show a
-- "migration in progress" footer; Core's PLAYER_LOGIN handler kicks
-- StartMigration when this is true.
function Ledger:IsMigrationPending()
  if not _loaded then loadFromDisk() end
  return (_workingMem and _workingMem.pendingMigration and
          #_workingMem.pendingMigration.entries > 0) and true or false
end

function Ledger:IsMigrationRunning()
  return _migration ~= nil
end

-- True between loadFromDisk detecting a legacy blob and the async
-- deserialise completing. Core's PLAYER_LOGIN kicks KickLegacyLoad
-- when this is true; that load promotes pendingLegacy → pendingMigration
-- and chains into StartMigration.
function Ledger:IsLegacyLoadPending()
  if not _loaded then loadFromDisk() end
  return (_workingMem and _workingMem.pendingLegacy) and true or false
end

function Ledger:IsLegacyLoadRunning()
  return _legacyLoad ~= nil
end

-- Async deserialise of the alpha14/15 legacy blob. Fires opts.onComplete
-- (ok, errOrNil) when the deserialised payload has been promoted into
-- _workingMem.pendingMigration (ready for Ledger:StartMigration).
--
-- Decompresses synchronously (cheap relative to deserialise; ~1s on a
-- 7MB compressed blob). Deserialise runs across C_Timer ticks via
-- LibSerialize:DeserializeAsync with a 1024-item yieldCheck so each
-- tick stays ~one-frame-worth of CPU.
--
-- opts:
--   onProgress    function(phase, hint)  -- phase = "deserialise"; hint = "tick"
--   onComplete    function(ok, errOrNil)
function Ledger:KickLegacyLoad(opts)
  if not (_workingMem and _workingMem.pendingLegacy) then return false end
  if _legacyLoad then return true end
  if not (LibSerialize and LibDeflate) then
    if opts and opts.onComplete then pcall(opts.onComplete, false, "libs unavailable") end
    return false
  end
  opts = opts or {}

  local pl = _workingMem.pendingLegacy
  local decompressed = LibDeflate:DecompressDeflate(pl.blob)
  if not decompressed then
    _workingMem.pendingLegacy = nil
    if opts.onComplete then pcall(opts.onComplete, false, "decompress failed") end
    return false
  end

  local YIELD_EVERY = 1024
  local handler
  local ok, err = pcall(function()
    handler = LibSerialize:DeserializeAsync(decompressed, {
      yieldCheck = function(scratch)
        scratch.count = (scratch.count or 0) + 1
        if scratch.count >= YIELD_EVERY then
          scratch.count = 0
          return true
        end
        return false
      end,
    })
  end)
  if not ok or not handler then
    _workingMem.pendingLegacy = nil
    if opts.onComplete then pcall(opts.onComplete, false, "DeserializeAsync init failed: " .. tostring(err)) end
    return false
  end

  _legacyLoad = { startedAt = time(), opts = opts }
  local delaySec = opts.delaySec or 0.005

  local function step()
    -- Cancellation: if Clear / WipeForLegacySeed nilled _legacyLoad
    -- mid-flight, short-circuit. The handler coroutine is then
    -- garbage-collected naturally.
    if not _legacyLoad then return end

    local resumeOk, completed, success, payload = pcall(handler)
    if not resumeOk then
      _legacyLoad = nil
      if _workingMem then _workingMem.pendingLegacy = nil end
      if opts.onComplete then pcall(opts.onComplete, false, "resume failed: " .. tostring(completed)) end
      return
    end
    if not completed then
      if opts.onProgress then pcall(opts.onProgress, "deserialise", "tick") end
      if C_Timer and C_Timer.After then
        C_Timer.After(delaySec, step)
      else
        step()
      end
      return
    end

    if not success or type(payload) ~= "table" then
      _legacyLoad = nil
      _workingMem.pendingLegacy = nil
      if opts.onComplete then pcall(opts.onComplete, false, "deserialised payload invalid") end
      return
    end

    -- Promote pendingLegacy → pendingMigration and clear the legacy
    -- placeholder. The on-disk legacy blob stays put until SaveToDisk
    -- after migration completes (existing belt-and-suspenders logic).
    _workingMem.pendingMigration = {
      entries = payload.entries or {},
      byId    = payload.byId or {},
    }
    _workingMem.pendingLegacy = nil
    _legacyLoad = nil

    if opts.onComplete then pcall(opts.onComplete, true, nil) end
  end

  step()
  return true
end

-- Kick off the chunked migration pass. Idempotent — second call while
-- a migration is already running is a no-op. Returns true if a pass
-- was started (or one was already running).
--
-- opts:
--   chunkSize    rows per timer tick (default 500)
--   delaySec     pause between ticks (default 0.05)
--   onProgress   function(phase, idx, total, key)
--                  phase = "route" — idx/total over pendingMigration
--                  phase = "flush" — idx/total over staging buckets, key set
--   onComplete   function(activeRows, archiveCount, archiveRows)
function Ledger:StartMigration(opts)
  if not _loaded then loadFromDisk() end
  if not (_workingMem and _workingMem.pendingMigration) then return false end
  if _migration then return true end
  opts = opts or {}
  _migration = {
    idx       = 0,
    total     = #_workingMem.pendingMigration.entries,
    chunkSize = opts.chunkSize or 500,
    delaySec  = opts.delaySec or 0.005,
    currentMonthStart = getCurrentMonthStart(),
    staging   = {},
    opts      = opts,
  }
  migrationStep()
  return true
end

-- ============================================================================
-- Seal (TLY-51): cut old rows out of active into archives
-- ============================================================================
--
-- Seal is the user-driven mechanism for shrinking the active set when
-- it exceeds the soft cap. Walks active.entries, partitions into rows
-- to keep (current-month + ≤maxRows newest) vs rows to archive (older
-- than cutTime), then routes the archive-bound rows through _staging
-- and FlushStaging into monthly archive blobs. The kept rows replace
-- active.entries.
--
-- Defaults match the spec's soft cap: cutTime = now - 60d, maxRows =
-- 25,000. Both can be overridden via opts (the test harness uses
-- aggressive cuts).
--
-- Seal is chunked because the bucket phase + the per-archive
-- serialise/compress add up on ledgers of the size testers are
-- hitting. Phase order:
--   1. Plan (sync)        — partition active into keep + seal lists.
--   2. Bucket (chunked)   — route seal list into _staging by month.
--   3. Apply (sync)       — swap active.entries to keep list, rebuild byId.
--   4. Flush (chunked)    — FlushStaging writes archives, merging with
--                            any pre-existing archive at each key.
-- onComplete(sealedRows, archivesWritten) fires after Flush completes.

local _seal = nil  -- in-flight seal state

local sealStep
sealStep = function()
  if not _seal then return end
  local m = _seal
  local active = db()

  if m.phase == "bucket" then
    local stop = math.min(m.bucketIdx + m.chunkSize, m.bucketTotal)
    while m.bucketIdx < stop do
      m.bucketIdx = m.bucketIdx + 1
      local e = m.toSeal[m.bucketIdx]
      if e and e.id then
        local mkey = (e.atTime and date("%Y-%m", e.atTime)) or "unknown"
        local bucket = _staging[mkey]
        if not bucket then
          bucket = { entries = {}, byId = {} }
          _staging[mkey] = bucket
        end
        if not bucket.byId[e.id] then
          bucket.byId[e.id] = true
          bucket.entries[#bucket.entries + 1] = e
        end
      end
    end
    if m.opts.onProgress then
      pcall(m.opts.onProgress, "bucket", m.bucketIdx, m.bucketTotal)
    end

    if m.bucketIdx < m.bucketTotal then
      if C_Timer and C_Timer.After then
        C_Timer.After(m.delaySec, sealStep)
      else
        sealStep()
      end
      return
    end

    -- Bucket phase done — apply toKeep to active synchronously, then
    -- enter flush phase via FlushStaging.
    local newById = {}
    for _, e in ipairs(m.toKeep) do
      if e.id then newById[e.id] = true end
    end
    active.entries = m.toKeep
    active.byId    = newById
    _dirty = true
    invalidateReconcileCache()

    m.phase = "flush"
    Ledger:FlushStaging({
      delaySec = m.delaySec,
      onProgress = function(idx, total, key, mergedRowCount)
        if m.opts.onProgress then
          pcall(m.opts.onProgress, "flush", idx, total, key)
        end
      end,
      onComplete = function(archivesWritten, rowsArchived)
        local sealed = m.bucketTotal
        local opts = m.opts
        _seal = nil
        if opts.onComplete then
          pcall(opts.onComplete, sealed, archivesWritten)
        end
      end,
    })
  end
end

-- Predict the cut without actually performing it. UI surfaces use this
-- to show "Seal will archive 12,440 rows from before 2025-12-15" before
-- the user clicks confirm.
function Ledger:SealPreview(opts)
  if not _loaded then loadFromDisk() end
  opts = opts or {}
  local now = time()
  local cutTime = opts.cutTime or (now - 60 * 86400)
  local maxRows = opts.maxRows or 25000

  local active = db()
  local keepCount, sealCount = 0, 0
  for _, e in ipairs(active.entries) do
    if (e.atTime or 0) >= cutTime then
      keepCount = keepCount + 1
    else
      sealCount = sealCount + 1
    end
  end
  if keepCount > maxRows then
    sealCount = sealCount + (keepCount - maxRows)
    keepCount = maxRows
  end
  return {
    activeCount = #active.entries,
    keepCount   = keepCount,
    sealCount   = sealCount,
    cutTime     = cutTime,
    maxRows     = maxRows,
  }
end

function Ledger:IsSealRunning()
  return _seal ~= nil
end

-- Run a seal pass. Returns (true) on start, (false, reason) on error
-- (already running, migration in progress, library missing, etc.).
--
-- opts:
--   cutTime      epoch — rows older than this go to archives. Default now-60d.
--   maxRows      cap on active size. Default 25000.
--   chunkSize    rows per bucket-phase tick (default 500)
--   delaySec     pause between ticks (default 0.05)
--   onPlan       function(keepCount, sealCount) — fires once after the plan phase
--   onProgress   function(phase, idx, total, key)
--                  phase = "bucket" — idx/total over rows being routed
--                  phase = "flush"  — idx/total over archives being written
--   onComplete   function(sealedRows, archivesWritten)
function Ledger:Seal(opts)
  if _seal then return false, "seal already in progress" end
  if self:IsMigrationRunning() then return false, "migration in progress" end
  if not (LibSerialize and LibDeflate) then return false, "compression libs unavailable" end
  opts = opts or {}

  local now = time()
  local cutTime = opts.cutTime or (now - 60 * 86400)
  local maxRows = opts.maxRows or 25000

  local active = db()

  -- Plan phase: partition active.entries into keep + seal.
  local toKeep, toSeal = {}, {}
  for _, e in ipairs(active.entries) do
    if (e.atTime or 0) >= cutTime then
      toKeep[#toKeep + 1] = e
    else
      toSeal[#toSeal + 1] = e
    end
  end

  -- Apply maxRows cap by trimming oldest from toKeep into toSeal.
  if #toKeep > maxRows then
    table.sort(toKeep, function(a, b) return (a.atTime or 0) > (b.atTime or 0) end)
    for i = maxRows + 1, #toKeep do
      toSeal[#toSeal + 1] = toKeep[i]
    end
    for i = #toKeep, maxRows + 1, -1 do
      toKeep[i] = nil
    end
  end

  if opts.onPlan then pcall(opts.onPlan, #toKeep, #toSeal) end

  if #toSeal == 0 then
    if opts.onComplete then pcall(opts.onComplete, 0, 0) end
    return true
  end

  _seal = {
    phase       = "bucket",
    toKeep      = toKeep,
    toSeal      = toSeal,
    bucketIdx   = 0,
    bucketTotal = #toSeal,
    chunkSize   = opts.chunkSize or 500,
    delaySec    = opts.delaySec or 0.005,
    opts        = opts,
  }
  sealStep()
  return true
end

-- ============================================================================
-- Insert
-- ============================================================================
--
-- Performance note (TLY-21): entries are append-only. We deliberately do NOT
-- maintain a sorted invariant on the storage list — sorting on every insert
-- was O(N log N) per row, which made bulk imports of TSM Accounting CSVs
-- (often tens of thousands of rows) burn seconds at PLAYER_LOGIN. Callers
-- that care about chronological order sort the result of Query(); the
-- ScrollTable UI sorts at render time anyway.

local function isValidEntry(e)
  if type(e) ~= "table" then return false end
  if type(e.id) ~= "string" or e.id == "" then return false end
  if type(e.atTime) ~= "number" or e.atTime <= 0 then return false end
  if type(e.kind) ~= "string" or e.kind == "" then return false end
  if type(e.source) ~= "string" or e.source == "" then return false end
  return true
end

-- Insert a single entry. Returns (true, entry) on insert, (false, reason)
-- on dedupe or invalid input. Caller is responsible for setting entry.id;
-- adapters typically use string.format("%s:%s", source, sourceId).
function Ledger:Insert(entry)
  if not isValidEntry(entry) then return false, "invalid entry" end
  local d = db()
  if d.byId[entry.id] then return false, "duplicate" end
  d.byId[entry.id] = true
  d.entries[#d.entries + 1] = entry
  _dirty = true
  invalidateReconcileCache()
  return true, entry
end

-- Batch insert. Returns (insertedCount, skippedCount).
function Ledger:InsertMany(entries)
  if type(entries) ~= "table" then return 0, 0 end
  local d = db()
  local inserted, skipped = 0, 0
  for _, entry in ipairs(entries) do
    if isValidEntry(entry) and not d.byId[entry.id] then
      d.byId[entry.id] = true
      d.entries[#d.entries + 1] = entry
      inserted = inserted + 1
    else
      skipped = skipped + 1
    end
  end
  if inserted > 0 then
    _dirty = true
    invalidateReconcileCache()
  end
  return inserted, skipped
end

-- ============================================================================
-- Query
-- ============================================================================
--
-- filter.window controls how much history the query covers:
--   "active" (default)  — only the in-memory active set (≤25k rows / 60d)
--   "<n>m"              — active + archives whose range overlaps the last
--                          N months (Compare opt-in, Lifecycle drill)
--   "all"               — active + every archive (full-history sweep;
--                          slow path, deliberately user-triggered)
--
-- Pages that don't pass filter.window get the snappy default. The "all"
-- path costs proportional to total archive row count and lazy-loads
-- every archive blob into Archive's LRU(3) cache as it walks.

-- Return the row source(s) a query should iterate. Lazy-loads any
-- archives needed to satisfy filter.window. Active is always included;
-- archives are appended in chronological order by key (oldest first).
local function gatherRows(filter)
  local d = db()
  local window = filter.window or "active"
  if window == "active" then return d.entries end
  if not ns.Archive then return d.entries end

  -- "<n>m" hints the lookback window for archive selection. Doesn't
  -- override an explicit filter.atTimeFrom — that always wins.
  local archiveFrom = filter.atTimeFrom
  if not archiveFrom and type(window) == "string" then
    local n = window:match("^(%d+)m$")
    if n then archiveFrom = time() - tonumber(n) * 30 * 86400 end
  end

  -- Archive:List returns keys sorted ascending — chronological for
  -- typical YYYY-MM[-pN] keys. archiveIndex carries fromTs/toTs without
  -- requiring the slot global to load, so we can range-prune cheaply.
  local archiveKeys = ns.Archive:List()

  local rows = {}
  for _, key in ipairs(archiveKeys) do
    local meta = ns.Archive:GetIndex(key) or ns.Archive:GetMeta(key)
    local skip = false
    if meta then
      if archiveFrom and meta.toTs and meta.toTs < archiveFrom then skip = true end
      if filter.atTimeTo and meta.fromTs and meta.fromTs > filter.atTimeTo then skip = true end
    end
    if not skip then
      local archive = ns.Archive:Load(key)
      if archive and archive.entries then
        for i = 1, #archive.entries do rows[#rows + 1] = archive.entries[i] end
      end
    end
  end

  -- Active set is appended last so newest-first sorts at the UI layer
  -- pull from the most recently accumulated rows first.
  for i = 1, #d.entries do rows[#rows + 1] = d.entries[i] end
  return rows
end

-- filter: optional table with any combination of:
--   kind, kinds (list), itemID, itemKey, charKey, source,
--   atTimeFrom, atTimeTo, window ("active" | "<n>m" | "all")
-- Returns a list of matching entries (refs into storage; do not mutate).
function Ledger:Query(filter)
  filter = filter or {}
  local kindSet
  if filter.kinds then
    kindSet = {}
    for _, k in ipairs(filter.kinds) do kindSet[k] = true end
  end

  local out = {}
  for _, e in ipairs(gatherRows(filter)) do
    local ok = true
    if filter.kind and e.kind ~= filter.kind then ok = false end
    if ok and kindSet and not kindSet[e.kind] then ok = false end
    if ok and filter.itemID and e.itemID ~= filter.itemID then ok = false end
    if ok and filter.itemKey and e.itemKey ~= filter.itemKey then ok = false end
    if ok and filter.charKey and e.charKey ~= filter.charKey then ok = false end
    if ok and filter.source and e.source ~= filter.source then ok = false end
    if ok and filter.atTimeFrom and e.atTime < filter.atTimeFrom then ok = false end
    if ok and filter.atTimeTo and e.atTime > filter.atTimeTo then ok = false end
    if ok then out[#out + 1] = e end
  end
  return out
end

-- Aggregate statistics over a filtered set. Convenience for UI.
function Ledger:Stats(filter)
  local rows = self:Query(filter)
  local stats = {
    count = #rows,
    income = 0, expense = 0, net = 0,
    byKind = {},
    bySource = {},
  }
  for _, e in ipairs(rows) do
    local copper = e.copper or 0
    local sign = self:KindSign(e.kind)
    if sign > 0 then stats.income = stats.income + copper
    elseif sign < 0 then stats.expense = stats.expense + copper end
    stats.byKind[e.kind] = (stats.byKind[e.kind] or 0) + 1
    stats.bySource[e.source] = (stats.bySource[e.source] or 0) + 1
  end
  stats.net = stats.income - stats.expense
  return stats
end

-- Returns +1 for income kinds, -1 for expense kinds, 0 for neutral tracking.
--
-- Income (+1):  sale, vendor-sell, mail-receive, refund, quest-reward,
--               loot, mission, crafting-order-fulfilled.
-- Expense (-1): purchase, vendor-buy, mail-send, repair, ah-fee, taxi,
--               trainer, trading-post, crafting-order-placed.
-- Neutral (0):  ah-cancel, ah-expire, ah-deposit, trade, unknown.
--   ah-deposit is paired with the eventual sale/expire/cancel at view time
--   (Lifecycle module) — gross deposit + outcome together yield the realized
--   loss/recovery. Counting deposit as a live expense would double-count
--   when the sale completes and TSM/Native attribute the cut.
--   unknown (TLY-29) is the catch-all bucket for adapter source-kinds we
--   don't yet recognize. Neutral by design — these rows are diagnostic,
--   not financial; treating them as either income or expense would corrupt
--   stats based on rows we haven't classified.
function Ledger:KindSign(kind)
  if kind == "sale" or kind == "vendor-sell" or kind == "mail-receive"
     or kind == "refund" or kind == "quest-reward" or kind == "loot"
     or kind == "mission" or kind == "crafting-order-fulfilled" then
    return 1
  elseif kind == "purchase" or kind == "vendor-buy" or kind == "mail-send"
         or kind == "repair" or kind == "ah-fee" or kind == "taxi"
         or kind == "trainer" or kind == "trading-post"
         or kind == "crafting-order-placed" then
    return -1
  end
  -- ah-cancel, ah-expire, ah-deposit, trade, unknown, and any future
  -- additions land here. Explicit fall-through keeps Schema-defined kinds
  -- and unrecognized strings indistinguishable for sign purposes — both
  -- correctly read as zero contribution to income/expense totals.
  return 0
end

-- ============================================================================
-- Source registry
-- ============================================================================

local sources = {}     -- name → { name, label, importFn, isAvailableFn }
local sourceOrder = {}

-- Register an adapter. opts:
--   label         — UI display name (default: name)
--   importFn      — function() that pulls from the source and calls
--                   Ledger:InsertMany. Returns (insertedCount, skippedCount).
--                   Legacy synchronous path; called by ImportFromAllSources.
--   getEntriesFn  — function() that returns (entries[], skippedAtParse).
--                   Used by ImportFromAllSourcesChunked so the driver can
--                   batch the insert phase with yields. Adapters that don't
--                   provide this fall back to importFn (synchronous).
--   isAvailable   — function() returning true if the source can be imported
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
    importFn = opts.importFn,
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

-- Run a single source's import. Returns (inserted, skipped, err).
function Ledger:ImportFromSource(name)
  local s = sources[name]
  if not s or not s.importFn then return 0, 0, "no such source" end
  if s.isAvailableFn then
    local ok, available = pcall(s.isAvailableFn)
    if not ok or not available then return 0, 0, "source unavailable" end
  end
  local ok, inserted, skipped = pcall(s.importFn)
  if not ok then return 0, 0, tostring(inserted) end
  return inserted or 0, skipped or 0, nil
end

-- Run every registered source's import. Returns a per-source result table.
function Ledger:ImportFromAllSources()
  local results = {}
  for _, name in ipairs(sourceOrder) do
    local inserted, skipped, err = self:ImportFromSource(name)
    results[#results + 1] = {
      source = name,
      inserted = inserted,
      skipped = skipped,
      error = err,
    }
  end
  return results
end

-- ============================================================================
-- Chunked import (TLY-25)
-- ============================================================================
--
-- Yield-aware batch insert. Inserts at most opts.chunkSize entries per tick,
-- waiting opts.delaySec between ticks via C_Timer.After. Callbacks fire after
-- each chunk so the wizard's progress widget can update live. Drives via
-- tail-call chain (no coroutine needed; the addon thread yields naturally
-- between C_Timer.After invocations).
--
-- opts:
--   chunkSize   default 500 — entries inserted per tick. Larger = faster
--               wall-clock import; smaller = friendlier framerate.
--   delaySec    default 0.05 — gap between ticks. 0.05s ≈ 3 frames at 60fps.
--   onProgress  function(insertedSoFar, totalAttempted, skippedSoFar)
--   onDone      function(inserted, skipped)
function Ledger:InsertManyChunked(entries, opts)
  opts = opts or {}
  local chunkSize = opts.chunkSize or 500
  local delaySec = opts.delaySec or 0.005

  if type(entries) ~= "table" or #entries == 0 then
    if opts.onDone then pcall(opts.onDone, 0, 0) end
    return
  end

  local d = db()
  local total = #entries
  local idx = 0
  local inserted = 0
  local skipped = 0

  local function step()
    local stop = math.min(idx + chunkSize, total)
    local chunkInserted = 0
    while idx < stop do
      idx = idx + 1
      local e = entries[idx]
      if isValidEntry(e) and not d.byId[e.id] then
        d.byId[e.id] = true
        d.entries[#d.entries + 1] = e
        inserted = inserted + 1
        chunkInserted = chunkInserted + 1
      else
        skipped = skipped + 1
      end
    end
    if chunkInserted > 0 then
      _dirty = true
      invalidateReconcileCache()
    end
    if opts.onProgress then pcall(opts.onProgress, inserted, total, skipped) end
    if idx < total and C_Timer and C_Timer.After then
      C_Timer.After(delaySec, step)
    else
      if opts.onDone then pcall(opts.onDone, inserted, skipped) end
    end
  end

  step()
end

-- ============================================================================
-- Routed chunked import — date-aware variant for backfill paths
-- ============================================================================
--
-- Same chunked-tick pattern as InsertManyChunked, but each row is routed
-- by atTime: current-month rows append to active (with dedupe) and prior-
-- month rows accumulate in the module-private _staging buckets keyed on
-- YYYY-MM. Rows missing atTime (rare; defensive) fall through to active.
--
-- This keeps the active set bounded during the wizard's sibling-addon
-- backfill — historic rows never inflate active, so a 438k-row TSM CSV
-- doesn't reproduce the pre-TLY-51 freeze.
--
-- The driver MUST call Ledger:FlushStaging after the last source completes
-- so the accumulated staging buckets become archives on disk. Until that
-- flush runs, prior-month rows live in memory only — a logout before
-- flush loses them.
--
-- opts:
--   chunkSize, delaySec   same as InsertManyChunked.
--   onProgress(insertedSoFar, total, skippedSoFar)
--   onDone(inserted, skipped, insertedActive, insertedStaging)
function Ledger:InsertManyChunkedRouted(entries, opts)
  opts = opts or {}
  local chunkSize = opts.chunkSize or 500
  local delaySec  = opts.delaySec or 0.005

  if type(entries) ~= "table" or #entries == 0 then
    if opts.onDone then pcall(opts.onDone, 0, 0, 0, 0) end
    return
  end

  local total = #entries
  local idx = 0
  local insertedActive, insertedStaging, skipped = 0, 0, 0
  local currentMonthStart = getCurrentMonthStart()

  local function step()
    local stop = math.min(idx + chunkSize, total)
    local chunkActive = 0
    while idx < stop do
      idx = idx + 1
      local e = entries[idx]
      if not isValidEntry(e) then
        skipped = skipped + 1
      else
        local active = db()
        local atT = e.atTime or 0
        if atT >= currentMonthStart or atT == 0 then
          if active.byId[e.id] then
            skipped = skipped + 1
          else
            active.byId[e.id] = true
            active.entries[#active.entries + 1] = e
            insertedActive = insertedActive + 1
            chunkActive = chunkActive + 1
          end
        else
          local mkey = date("%Y-%m", atT)
          local bucket = _staging[mkey]
          if not bucket then
            bucket = { entries = {}, byId = {} }
            _staging[mkey] = bucket
          end
          if bucket.byId[e.id] then
            skipped = skipped + 1
          else
            bucket.byId[e.id] = true
            bucket.entries[#bucket.entries + 1] = e
            insertedStaging = insertedStaging + 1
          end
        end
      end
    end
    if chunkActive > 0 then
      _dirty = true
      invalidateReconcileCache()
    end
    if opts.onProgress then
      pcall(opts.onProgress, insertedActive + insertedStaging, total, skipped)
    end
    if idx < total and C_Timer and C_Timer.After then
      C_Timer.After(delaySec, step)
    else
      if opts.onDone then
        pcall(opts.onDone, insertedActive + insertedStaging, skipped, insertedActive, insertedStaging)
      end
    end
  end

  step()
end

-- ============================================================================
-- FlushStaging — write _staging buckets out as archives
-- ============================================================================
--
-- Walks a flush plan one entry per turn. Each plan entry is a
-- (key, entries, byId) tuple; large staging buckets are split into
-- numbered parts (`YYYY-MM-pN`) so no single archive write exceeds the
-- soft cap. For each entry, merges with any existing archive at the
-- same key (deduping by entry id) and saves the combined result via
-- the async serialise path so the per-archive serialise step never
-- blocks the input thread for more than one yieldCheck slice.
--
-- Merging matters when the same backfill run produces rows for a month
-- that already has an archive on disk (e.g., user adds a new source mid-
-- life; their existing archives stay, the new source's rows get folded
-- in). For a fresh-install backfill there's nothing to merge against
-- and the merge is a no-op.
--
-- Subdivision rationale: a 50k-row monthly bucket serialises in one
-- ~5-second freeze on slower machines even with the async API, because
-- the resulting Lua string is large and LibDeflate compress is the
-- final blocking step. Capping each part at PART_CAP rows keeps the
-- final compress under ~100ms while the async serialise stays bounded
-- per yield. Spec calls this out as "auto-subdivide weekly if a month
-- exceeds 50k rows"; Phase 1 uses a smaller threshold + a "-pN" suffix
-- since archive granularity is opaque to the rest of the system.
--
-- opts:
--   delaySec    pause between bucket flushes (default 0.05)
--   onProgress  function(idx, total, key, mergedRowCount)
--   onComplete  function(archivesWritten, rowsArchived)

local PART_CAP = 5000

function Ledger:GetStagingKeys()
  local out = {}
  for k in pairs(_staging) do out[#out + 1] = k end
  table.sort(out)
  return out
end

function Ledger:GetStagingRowCount()
  local total = 0
  for _, bucket in pairs(_staging) do total = total + #bucket.entries end
  return total
end

function Ledger:FlushStaging(opts)
  opts = opts or {}
  local delaySec = opts.delaySec or 0.005
  local keys = self:GetStagingKeys()

  if #keys == 0 then
    if opts.onComplete then pcall(opts.onComplete, 0, 0) end
    return
  end

  -- Build the flush plan: subdivide oversized buckets into parts so no
  -- single Archive:SaveAsync call processes more than PART_CAP rows.
  -- Each plan entry will become one async-serialise pass.
  local plan = {}
  for _, key in ipairs(keys) do
    local bucket = _staging[key]
    if bucket and #bucket.entries > 0 then
      if #bucket.entries <= PART_CAP then
        plan[#plan + 1] = { key = key, bucket = bucket }
      else
        local parts = math.ceil(#bucket.entries / PART_CAP)
        for p = 1, parts do
          local startIdx = (p - 1) * PART_CAP + 1
          local endIdx   = math.min(p * PART_CAP, #bucket.entries)
          local partEntries, partById = {}, {}
          for i = startIdx, endIdx do
            local e = bucket.entries[i]
            partEntries[#partEntries + 1] = e
            if e.id then partById[e.id] = true end
          end
          plan[#plan + 1] = {
            key       = key .. "-p" .. tostring(p),
            partOfKey = key,
            entries   = partEntries,
            byId      = partById,
            bucket    = nil,
          }
        end
        -- Clear the original bucket — its rows are now distributed across
        -- parts. Each part holds its own entries/byId.
        _staging[key] = nil
      end
    end
  end

  -- Drop any keys we already cleared from staging.
  if #plan == 0 then
    if opts.onComplete then pcall(opts.onComplete, 0, 0) end
    return
  end

  local idx = 0
  local archivesWritten, rowsArchived = 0, 0

  local function next()
    if idx >= #plan then
      invalidateReconcileCache()
      if opts.onComplete then pcall(opts.onComplete, archivesWritten, rowsArchived) end
      return
    end
    idx = idx + 1
    local entry = plan[idx]

    -- Resolve the entries/byId for this plan slot. Single-bucket entries
    -- pull from staging; subdivided parts have inline entries already.
    local entries, byId
    if entry.bucket then
      entries, byId = entry.bucket.entries, entry.bucket.byId
    else
      entries, byId = entry.entries, entry.byId
    end

    if not (ns.Archive and ns.Archive.SaveAsync) then
      -- Fallback: synchronous Save for the rare no-async case.
      if ns.Archive and ns.Archive.Save then
        ns.Archive:Save(entry.key, entries, { byId = byId })
      end
      archivesWritten = archivesWritten + 1
      rowsArchived = rowsArchived + #entries
      if entry.bucket then _staging[entry.partOfKey or entry.key] = nil end
      if opts.onProgress then pcall(opts.onProgress, idx, #plan, entry.key, #entries) end
      if C_Timer and C_Timer.After then C_Timer.After(delaySec, next) else next() end
      return
    end

    -- Merge with existing archive at the same key (dedupe by entry id).
    -- LoadAsync drives the merge-load deserialise across ticks so each
    -- per-archive cycle stays smooth; the synchronous Load call here
    -- previously dropped frame rate to ~10 fps on slower CPUs.
    local rowCount = #entries
    local function continueAfterLoad(existing)
      local mergedEntries, mergedById = {}, {}
      if existing and existing.entries then
        for _, e in ipairs(existing.entries) do
          if e.id and not mergedById[e.id] then
            mergedById[e.id] = true
            mergedEntries[#mergedEntries + 1] = e
          end
        end
      end
      for _, e in ipairs(entries) do
        if e.id and not mergedById[e.id] then
          mergedById[e.id] = true
          mergedEntries[#mergedEntries + 1] = e
        end
      end

      ns.Archive:SaveAsync(entry.key, mergedEntries, {
        byId     = mergedById,
        delaySec = delaySec,
        onComplete = function(ok, bytes, err)
          archivesWritten = archivesWritten + 1
          rowsArchived = rowsArchived + rowCount
          if entry.bucket then
            _staging[entry.partOfKey or entry.key] = nil
          end
          invalidateReconcileCache()
          if opts.onProgress then
            pcall(opts.onProgress, idx, #plan, entry.key, #mergedEntries)
          end
          if C_Timer and C_Timer.After then
            C_Timer.After(delaySec, next)
          else
            next()
          end
        end,
      })
    end

    if ns.Archive.LoadAsync then
      ns.Archive:LoadAsync(entry.key, {
        delaySec = delaySec,
        onComplete = continueAfterLoad,
      })
    else
      continueAfterLoad(ns.Archive:Load(entry.key))
    end
  end

  next()
end

-- Multi-source chunked driver. Walks registered sources in order, awaiting
-- each source's parse + chunked insert before starting the next. Designed to
-- be called from the setup wizard's onComplete; surfaces per-source progress
-- to a UI/ProgressBar.lua widget via callbacks.
--
-- Sources that expose getEntriesFn use the chunked-insert path. Sources with
-- only the legacy importFn (Native — event-driven, near-zero rows) run
-- synchronously between chunked sources.
--
-- After every chunked source completes, the driver fires Ledger:FlushStaging
-- once at the end so prior-month rows that accumulated during the import
-- land on disk as archives before opts.onComplete is delivered to the
-- caller. The wizard's progress widget gets a final "flushing archives"
-- phase via opts.onSourceProgress("__flush", idx, total, key) callbacks.
--
-- opts:
--   chunkSize    forwarded to InsertManyChunkedRouted
--   delaySec     forwarded to InsertManyChunkedRouted
--   sourceDelay  default 0.5 — pause between sources so the input thread
--                doesn't stay starved across an entire import.
--   onSourceStart    function(name, label, parsedCount)
--   onSourceProgress function(name, insertedSoFar, total, skippedSoFar)
--   onSourceDone     function(name, inserted, skipped)
--   onFlushStart     function(archiveCount)
--   onFlushProgress  function(idx, total, key, mergedRowCount)
--   onComplete       function(results) — results = list of per-source rows
function Ledger:ImportFromAllSourcesChunked(opts)
  opts = opts or {}
  local sourceDelay = opts.sourceDelay or 0.5

  local results = {}
  local sourceIdx = 0

  -- Final phase: flush any staging buckets accumulated during routed
  -- imports, then fire the user's onComplete with the per-source results.
  local function finishWithFlush()
    local stagingKeys = self:GetStagingKeys()
    if opts.onFlushStart then pcall(opts.onFlushStart, #stagingKeys) end
    self:FlushStaging({
      delaySec = opts.delaySec,
      onProgress = function(idx, total, key, mergedRowCount)
        if opts.onFlushProgress then
          pcall(opts.onFlushProgress, idx, total, key, mergedRowCount)
        end
      end,
      onComplete = function(archivesWritten, rowsArchived)
        if opts.onComplete then pcall(opts.onComplete, results, archivesWritten, rowsArchived) end
      end,
    })
  end

  local function nextSource()
    sourceIdx = sourceIdx + 1
    if sourceIdx > #sourceOrder then
      return finishWithFlush()
    end

    local name = sourceOrder[sourceIdx]
    local s = sources[name]
    if not s then return nextSource() end
    -- IsSourceAvailable also enforces TallyDB.disabledSources opt-out,
    -- so sources the user unchecked in the wizard land here cleanly.
    if not self:IsSourceAvailable(name) then
      results[#results + 1] = { source = name, inserted = 0, skipped = 0, skippedSource = true }
      if opts.onSourceSkipped then pcall(opts.onSourceSkipped, name, s.label) end
      return nextSource()
    end

    -- Prefer the chunkable getEntriesFn path. Falls back to importFn for
    -- adapters that haven't been migrated (e.g., Native, where the import
    -- is event-driven and produces ~0 rows per call anyway).
    if s.getEntriesFn then
      local ok, entries, parseSkipped = pcall(s.getEntriesFn)
      if not ok then
        results[#results + 1] = { source = name, inserted = 0, skipped = 0, error = tostring(entries) }
        return nextSource()
      end
      entries = entries or {}
      parseSkipped = parseSkipped or 0
      if opts.onSourceStart then pcall(opts.onSourceStart, name, s.label, #entries) end

      self:InsertManyChunkedRouted(entries, {
        chunkSize = opts.chunkSize,
        delaySec = opts.delaySec,
        onProgress = function(inserted, total, skipped)
          if opts.onSourceProgress then pcall(opts.onSourceProgress, name, inserted, total, skipped) end
        end,
        onDone = function(inserted, skipped, insertedActive, insertedStaging)
          results[#results + 1] = {
            source = name,
            inserted = inserted,
            skipped = skipped + parseSkipped,
            insertedActive = insertedActive,
            insertedStaging = insertedStaging,
          }
          if opts.onSourceDone then pcall(opts.onSourceDone, name, inserted, skipped + parseSkipped) end
          if C_Timer and C_Timer.After then
            C_Timer.After(sourceDelay, nextSource)
          else
            nextSource()
          end
        end,
      })
    else
      -- Legacy path: synchronous. Native lives here (0-N invoice rows from
      -- the open inbox; cheap regardless). importFn writes to active via
      -- InsertMany — historic atTimes from a synchronous Native scan are
      -- rare enough that we don't need to route this path for Phase 1.
      if opts.onSourceStart then pcall(opts.onSourceStart, name, s.label, nil) end
      local ok, inserted, skipped = pcall(s.importFn or function() return 0, 0 end)
      if not ok then
        results[#results + 1] = { source = name, inserted = 0, skipped = 0, error = tostring(inserted) }
      else
        results[#results + 1] = { source = name, inserted = inserted or 0, skipped = skipped or 0 }
        if opts.onSourceDone then pcall(opts.onSourceDone, name, inserted or 0, skipped or 0) end
      end
      if C_Timer and C_Timer.After then
        C_Timer.After(sourceDelay, nextSource)
      else
        nextSource()
      end
    end
  end

  nextSource()
end

-- ============================================================================
-- Source comparison (TLY-27)
-- ============================================================================
--
-- Aligns rows from two sources into one row-by-row diff view. Match tiers,
-- in fall-through order:
--   strict — same (charKey, itemID, count, copper) within ±60s
--   loose  — same (charKey, itemID, count) within ±5min (ignores copper)
--   name   — same (charKey, lower(itemName)) within ±5min (TLY-37; only
--            considered when A has nil itemID + a non-empty name. Connects
--            historical rows that pre-date itemID resolution at the adapter
--            source against rows that have it populated.)
--   fuzzy  — same (charKey, itemID) within ±1h (ignores count + copper)
--
-- Returns a list of pairs:
--   { a = entryA|nil, b = entryB|nil, tier = "strict"|"loose"|"name"|"fuzzy"|"unique" }
--
-- Rows present in only one source render with the other side nil and
-- tier = "unique". Same source appearing in both A and B (sourceA ==
-- sourceB) is a no-op self-pair — we early-return empty.

local STRICT_WINDOW = 60
local LOOSE_WINDOW = 5 * 60
local FUZZY_WINDOW = 60 * 60

-- Pull a comparable name string off a ledger entry. Adapters write the
-- player-facing item name into either `meta.name` (Native, FlipQueue) or
-- `meta.itemName` (some Journalator paths), so we accept either. Lowercased
-- for case-insensitive matching.
local function nameOf(entry)
  if not entry or type(entry.meta) ~= "table" then return nil end
  local name = entry.meta.name or entry.meta.itemName
  if type(name) ~= "string" or name == "" then return nil end
  return string.lower(name)
end

-- Index a row list for O(1) match lookups. Keyed by (charKey, itemID); each
-- bucket holds the chronologically-ordered rows.
local function indexByCharItem(rows)
  local idx = {}
  for _, e in ipairs(rows) do
    if e.charKey and e.itemID then
      local key = e.charKey .. "|" .. tostring(e.itemID)
      idx[key] = idx[key] or {}
      table.insert(idx[key], e)
    end
  end
  for _, list in pairs(idx) do
    table.sort(list, function(a, b) return (a.atTime or 0) < (b.atTime or 0) end)
  end
  return idx
end

-- Secondary index for the name-tier fallback. Keyed by (charKey, lower(name));
-- only populated for entries with a non-empty meta.name / meta.itemName.
local function indexByCharName(rows)
  local idx = {}
  for _, e in ipairs(rows) do
    local name = nameOf(e)
    if e.charKey and name then
      local key = e.charKey .. "|" .. name
      idx[key] = idx[key] or {}
      table.insert(idx[key], e)
    end
  end
  for _, list in pairs(idx) do
    table.sort(list, function(a, b) return (a.atTime or 0) < (b.atTime or 0) end)
  end
  return idx
end

-- Find a match for entry `a` in `bucket` (B-side rows for the same charKey
-- + itemID). Returns (entry, tier) or nil. Skips entries in `consumed`.
local function findMatch(a, bucket, consumed)
  if not bucket then return nil end
  local aT = a.atTime or 0
  local aCount = a.count or 1
  local aCopper = a.copper or 0

  -- Pass 1: strict.
  for _, b in ipairs(bucket) do
    if not consumed[b]
       and math.abs((b.atTime or 0) - aT) <= STRICT_WINDOW
       and (b.count or 1) == aCount
       and (b.copper or 0) == aCopper then
      return b, "strict"
    end
  end
  -- Pass 2: loose.
  for _, b in ipairs(bucket) do
    if not consumed[b]
       and math.abs((b.atTime or 0) - aT) <= LOOSE_WINDOW
       and (b.count or 1) == aCount then
      return b, "loose"
    end
  end
  -- Pass 3: fuzzy.
  for _, b in ipairs(bucket) do
    if not consumed[b]
       and math.abs((b.atTime or 0) - aT) <= FUZZY_WINDOW then
      return b, "fuzzy"
    end
  end
  return nil
end

-- Name-tier match: chronologically-nearest unconsumed B-row in the same
-- (charKey, name) bucket within LOOSE_WINDOW. Used only when the primary
-- (charKey, itemID) pass returns nil for an A-row that has no itemID.
local function findNameMatch(a, bucket, consumed)
  if not bucket then return nil end
  local aT = a.atTime or 0
  for _, b in ipairs(bucket) do
    if not consumed[b]
       and math.abs((b.atTime or 0) - aT) <= LOOSE_WINDOW then
      return b, "name"
    end
  end
  return nil
end

-- Special pseudo-source meaning "every row in the Tally ledger,
-- regardless of which adapter wrote it." Lets the Compare view answer
-- "is my ledger up to date with this source?" instead of just
-- "do source X and source Y agree." Picked from the dropdown when
-- the user wants to see a source's data alongside their actual ledger.
Ledger.PSEUDO_SOURCE_LEDGER = "__ledger"

function Ledger:Compare(sourceA, sourceB, filter)
  if not sourceA or not sourceB then return {}, {} end
  if sourceA == sourceB then return {}, {} end

  filter = filter or {}

  -- The ledger pseudo-source maps to "no source filter" — Query then
  -- returns every entry from every adapter. Real source names map to
  -- a normal {source = name} filter.
  local function queryFor(name)
    if name == self.PSEUDO_SOURCE_LEDGER then
      return self:Query(filter)
    end
    return self:Query(setmetatable({ source = name }, { __index = filter }))
  end

  local rowsA = queryFor(sourceA)
  local rowsB = queryFor(sourceB)

  local indexB = indexByCharItem(rowsB)
  local indexBByName = indexByCharName(rowsB)
  local consumed = {}
  local pairs_out = {}

  -- Walk A in chronological order.
  table.sort(rowsA, function(a, b) return (a.atTime or 0) < (b.atTime or 0) end)

  for _, a in ipairs(rowsA) do
    local key = (a.charKey or "?") .. "|" .. tostring(a.itemID or 0)
    local bucket = indexB[key]
    local match, tier = findMatch(a, bucket, consumed)
    if not match and not a.itemID then
      local aName = nameOf(a)
      if aName then
        local nameKey = (a.charKey or "?") .. "|" .. aName
        match, tier = findNameMatch(a, indexBByName[nameKey], consumed)
      end
    end
    if match then
      consumed[match] = true
      pairs_out[#pairs_out + 1] = { a = a, b = match, tier = tier }
    else
      pairs_out[#pairs_out + 1] = { a = a, b = nil, tier = "unique" }
    end
  end

  -- B-side leftovers: rows that nothing in A matched.
  for _, b in ipairs(rowsB) do
    if not consumed[b] then
      pairs_out[#pairs_out + 1] = { a = nil, b = b, tier = "unique" }
    end
  end

  -- Summary stats.
  local stats = {
    aCount = #rowsA, bCount = #rowsB,
    strict = 0, loose = 0, name = 0, fuzzy = 0,
    aOnly = 0, bOnly = 0,
    aCopper = 0, bCopper = 0,
    deltaCopper = 0,
  }
  for _, e in ipairs(rowsA) do stats.aCopper = stats.aCopper + (e.copper or 0) end
  for _, e in ipairs(rowsB) do stats.bCopper = stats.bCopper + (e.copper or 0) end
  stats.deltaCopper = stats.aCopper - stats.bCopper
  for _, p in ipairs(pairs_out) do
    if p.tier == "strict" then stats.strict = stats.strict + 1
    elseif p.tier == "loose" then stats.loose = stats.loose + 1
    elseif p.tier == "name" then stats.name = stats.name + 1
    elseif p.tier == "fuzzy" then stats.fuzzy = stats.fuzzy + 1
    elseif p.tier == "unique" then
      if p.a and not p.b then stats.aOnly = stats.aOnly + 1
      elseif p.b and not p.a then stats.bOnly = stats.bOnly + 1 end
    end
  end

  return pairs_out, stats
end

-- ============================================================================
-- Maintenance
-- ============================================================================

-- Wipe all entries — active set, every archive, and the archive index.
-- Sources can be re-imported afterward via /tally setup.
function Ledger:Clear()
  TallyDB = TallyDB or {}
  -- Clear archive slot globals first so their SV files become empty
  -- on next logout. Walk the slot table before nuking it.
  if ns.Archive then
    for _, key in ipairs(ns.Archive:List()) do
      ns.Archive:Delete(key)
    end
    ns.Archive:UnloadAll()
  end
  TallyDB.ledger = {}  -- drop active blob + activeMeta + archives + archiveSlots + archiveIndex + nextSlot
  _workingMem = defaultMem()
  _loaded = true
  _dirty = true
  _staging = {}
  _legacyLoad = nil  -- cancel any in-flight legacy deserialise
  invalidateReconcileCache()
end

-- Stress-test escape hatch for /tally seed legacy. Wipes in-memory
-- active + staging + dirty flag so PLAYER_LOGOUT's SaveToDisk skips
-- (no _dirty) and doesn't overwrite TallyDB.ledger.blob with a
-- fresh-empty active blob. Without this, seed legacy + /reload would
-- never actually exercise the legacy migration path because the
-- active blob's save would clear the legacy blob mid-flight.
--
-- Destructive: the caller's real ledger goes away. Only used by
-- /tally seed legacy after writing the synthetic legacy blob; not a
-- public Ledger API.
function Ledger:WipeForLegacySeed()
  _workingMem = defaultMem()
  _loaded = true
  _dirty = false
  _staging = {}
  _legacyLoad = nil  -- cancel any in-flight legacy deserialise
  if ns.Archive then ns.Archive:UnloadAll() end
  invalidateReconcileCache()
end

-- Drop entries from a specific source. Two variants:
--
--   ClearSource(sourceName)
--     Synchronous wipe of active rows only. Returns the number of
--     active rows removed. Archive rows for the same source are
--     untouched — call ClearSourceAsync below to reach archives too.
--     Suitable for small ledgers and call sites that don't tolerate
--     async (e.g. wizard reset where the caller drives next-step
--     transitions immediately).
--
--   ClearSourceAsync(sourceName, opts)
--     Walks active synchronously (fast — bounded by active size cap),
--     then walks each archive across C_Timer ticks: load, filter,
--     either Delete (if all rows removed) or SaveAsync (if some
--     remain). The async per-archive Save means each tick stays
--     within the input-thread budget even when 30+ archives need
--     rewriting on a big-ledger source clear.
--
--     opts:
--       delaySec    pause between archive ticks (default 0.05)
--       onProgress  function(idx, total, key, removedSoFar)
--       onComplete  function(totalRemoved)
function Ledger:ClearSource(sourceName)
  local d = db()
  local kept = {}
  local removed = 0
  for _, e in ipairs(d.entries) do
    if e.source == sourceName then
      d.byId[e.id] = nil
      removed = removed + 1
    else
      kept[#kept + 1] = e
    end
  end
  d.entries = kept
  if removed > 0 then
    _dirty = true
    invalidateReconcileCache()
  end
  return removed
end

function Ledger:ClearSourceAsync(sourceName, opts)
  opts = opts or {}
  local delaySec = opts.delaySec or 0.005

  -- Phase 1: active. Synchronous; bounded by the active soft cap.
  local removed = self:ClearSource(sourceName)

  if not ns.Archive then
    if opts.onComplete then pcall(opts.onComplete, removed) end
    return
  end

  local keys = ns.Archive:List()
  if #keys == 0 then
    if opts.onComplete then pcall(opts.onComplete, removed) end
    return
  end

  local idx = 0
  local function nextArchive()
    if idx >= #keys then
      if opts.onComplete then pcall(opts.onComplete, removed) end
      return
    end
    idx = idx + 1
    local key = keys[idx]

    -- Fast paths via archiveIndex. computeIndex tracks sourceCounts
    -- per archive, so we can answer "do I need to deserialise this
    -- archive at all?" without touching the blob:
    --   * sourceCount == 0 → archive has no rows from sourceName;
    --                         skip the Load entirely.
    --   * sourceCount == archive.count → archive is exclusively this
    --                         source; Delete without Load.
    --   * otherwise → fall through to the Load+filter+SaveAsync path.
    --
    -- Big speedup for /tally seed clear (every seeded archive is 100%
    -- __seed → straight Delete) and for real ClearSource("tsm") on
    -- a ledger where some archives only have FlipQueue/Native rows.
    local index = ns.Archive.GetIndex and ns.Archive:GetIndex(key) or nil
    if index and index.sourceCounts then
      local srcCount = index.sourceCounts[sourceName] or 0
      if srcCount == 0 then
        if opts.onProgress then pcall(opts.onProgress, idx, #keys, key, removed) end
        if C_Timer and C_Timer.After then C_Timer.After(delaySec, nextArchive) else nextArchive() end
        return
      elseif srcCount >= (index.count or 0) then
        ns.Archive:Delete(key)
        removed = removed + srcCount
        invalidateReconcileCache()
        if opts.onProgress then pcall(opts.onProgress, idx, #keys, key, removed) end
        if C_Timer and C_Timer.After then C_Timer.After(delaySec, nextArchive) else nextArchive() end
        return
      end
      -- Mixed-source archive — fall through to Load+filter+Save.
    end

    -- Slow path: archive contains at least one source-X row plus other
    -- sources, OR archiveIndex doesn't have sourceCounts (legacy
    -- archive predating this change). Load via DeserializeAsync,
    -- filter, rewrite via SerializeAsync.
    local function continueAfterLoad(archive)
      if not archive or not archive.entries then
        if opts.onProgress then pcall(opts.onProgress, idx, #keys, key, removed) end
        if C_Timer and C_Timer.After then C_Timer.After(delaySec, nextArchive) else nextArchive() end
        return
      end

      local archiveKept, archiveRemoved = {}, 0
      for _, e in ipairs(archive.entries) do
        if e.source == sourceName then
          archiveRemoved = archiveRemoved + 1
        else
          archiveKept[#archiveKept + 1] = e
        end
      end

      if archiveRemoved == 0 then
        if opts.onProgress then pcall(opts.onProgress, idx, #keys, key, removed) end
        if C_Timer and C_Timer.After then C_Timer.After(delaySec, nextArchive) else nextArchive() end
        return
      end

      removed = removed + archiveRemoved

      if #archiveKept == 0 then
        ns.Archive:Delete(key)
        invalidateReconcileCache()
        if opts.onProgress then pcall(opts.onProgress, idx, #keys, key, removed) end
        if C_Timer and C_Timer.After then C_Timer.After(delaySec, nextArchive) else nextArchive() end
        return
      end

      ns.Archive:SaveAsync(key, archiveKept, {
        delaySec = delaySec,
        onComplete = function(ok, bytes)
          invalidateReconcileCache()
          if opts.onProgress then pcall(opts.onProgress, idx, #keys, key, removed) end
          if C_Timer and C_Timer.After then C_Timer.After(delaySec, nextArchive) else nextArchive() end
        end,
      })
    end

    if ns.Archive.LoadAsync then
      ns.Archive:LoadAsync(key, {
        delaySec = delaySec,
        onComplete = continueAfterLoad,
      })
    else
      continueAfterLoad(ns.Archive:Load(key))
    end
  end

  nextArchive()
end

-- Total row count across active + archives + any pending-migration
-- buffer. Archive counts come from the metadata (no blob loads). The
-- pending-migration term keeps the grandfather check (Core's
-- PLAYER_LOGIN) accurate for users mid-upgrade — their data is real,
-- it just hasn't been routed into the new shape yet.
function Ledger:Count()
  local total = #db().entries
  if ns.Archive and ns.Archive.List then
    for _, key in ipairs(ns.Archive:List()) do
      local meta = ns.Archive:GetIndex(key) or ns.Archive:GetMeta(key)
      if meta then total = total + (meta.count or 0) end
    end
  end
  if _workingMem and _workingMem.pendingMigration then
    total = total + #_workingMem.pendingMigration.entries
  end
  -- Legacy blob waiting for async deserialise — count from blobMeta
  -- so the grandfather check sees the user as already-onboarded
  -- before the load completes.
  if _workingMem and _workingMem.pendingLegacy and _workingMem.pendingLegacy.meta then
    total = total + (_workingMem.pendingLegacy.meta.count or 0)
  end
  return total
end

-- ============================================================================
-- Setup gate (TLY-25)
-- ============================================================================
--
-- Returns true once the user has completed the setup wizard (or has been
-- grandfathered as a pre-wizard upgrader). Source adapters and the
-- import drivers respect this gate — until it returns true, no rows
-- flow into the ledger from any source. The wizard's onComplete
-- handler is the only thing that flips it on.
--
-- Why gate every path: testers reported that even after `/tally reset`
-- (which clears the gate), the deferred PLAYER_LOGIN import + the
-- 5-minute ticker + mailbox scans kept silently writing rows. The
-- expected behavior is "nothing imported until I finish the wizard."
function Ledger:IsSetupComplete()
  return TallyDB and TallyDB.setup and TallyDB.setup.completed and true or false
end
