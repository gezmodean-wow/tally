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
function Ledger:Reconcile(filter)
  local rows = self:Query(filter)
  if #rows == 0 then return {} end

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
        return
      end
    end
    print("|cffff8080Tally:|r ledger active set failed to load — starting fresh. Run /tally setup to backfill from sibling sources.")
    _workingMem = defaultMem()
    _loaded = true
    _dirty = false
    return
  end

  -- Migration 1: alpha14/15 single-blob. Promote into active; mark dirty
  -- so the next save lands the new shape. Retain L.blob on disk until the
  -- first new-shape save completes (SaveToDisk clears the legacy fields).
  if L.blob then
    local decompressed = LibDeflate:DecompressDeflate(L.blob)
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
        _dirty = true
        return
      end
    end
    print("|cffff8080Tally:|r ledger storage failed to load — starting fresh. Run /tally setup to backfill from sibling sources.")
    _workingMem = defaultMem()
    _loaded = true
    _dirty = false
    return
  end

  -- Migration 2: pre-alpha14 raw entries.
  if L.entries then
    _workingMem = {
      active = {
        entries = L.entries,
        byId    = L.byId or {},
      },
    }
    _loaded = true
    _dirty = true
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

  local archiveCount, archiveBytes, archiveRows = 0, 0, 0
  for _, rec in pairs(L.archives or {}) do
    archiveCount = archiveCount + 1
    archiveBytes = archiveBytes + (rec.bytes or 0)
    archiveRows  = archiveRows + (rec.count or 0)
  end

  local cachedKeys, cacheCap = {}, 0
  if ns.Archive then
    cachedKeys = ns.Archive:CachedKeys()
    cacheCap   = ns.Archive:CacheCap()
  end

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
    -- Back-compat aliases for callers still using the pre-TLY-51 names:
    blobBytes        = meta and meta.bytes or 0,
    blobCount        = meta and meta.count or 0,
    blobSavedAt      = meta and meta.savedAt or nil,
    legacyPresent    = (L.entries or L.blob) and true or false,
  }
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
  if inserted > 0 then _dirty = true end
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

  TallyDB = TallyDB or {}
  TallyDB.ledger = TallyDB.ledger or {}
  local archives = TallyDB.ledger.archives or {}

  -- "<n>m" hints the lookback window for archive selection. Doesn't
  -- override an explicit filter.atTimeFrom — that always wins.
  local archiveFrom = filter.atTimeFrom
  if not archiveFrom and type(window) == "string" then
    local n = window:match("^(%d+)m$")
    if n then archiveFrom = time() - tonumber(n) * 30 * 86400 end
  end

  -- Sort keys ascending so the concatenated list stays in roughly
  -- chronological order (active is always newest at end).
  local archiveKeys = {}
  for k in pairs(archives) do archiveKeys[#archiveKeys + 1] = k end
  table.sort(archiveKeys)

  local rows = {}
  for _, key in ipairs(archiveKeys) do
    local meta = archives[key]
    local skip = false
    if archiveFrom and meta.toTs and meta.toTs < archiveFrom then skip = true end
    if filter.atTimeTo and meta.fromTs and meta.fromTs > filter.atTimeTo then skip = true end
    if not skip and ns.Archive then
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
  local delaySec = opts.delaySec or 0.05

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
    while idx < stop do
      idx = idx + 1
      local e = entries[idx]
      if isValidEntry(e) and not d.byId[e.id] then
        d.byId[e.id] = true
        d.entries[#d.entries + 1] = e
        inserted = inserted + 1
      else
        skipped = skipped + 1
      end
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

-- Multi-source chunked driver. Walks registered sources in order, awaiting
-- each source's parse + chunked insert before starting the next. Designed to
-- be called from the setup wizard's onComplete; surfaces per-source progress
-- to a UI/ProgressBar.lua widget via callbacks.
--
-- Sources that expose getEntriesFn use the chunked-insert path. Sources with
-- only the legacy importFn (Native — event-driven, near-zero rows) run
-- synchronously between chunked sources.
--
-- opts:
--   chunkSize    forwarded to InsertManyChunked
--   delaySec     forwarded to InsertManyChunked
--   sourceDelay  default 0.5 — pause between sources so the input thread
--                doesn't stay starved across an entire import.
--   onSourceStart    function(name, label, parsedCount)
--   onSourceProgress function(name, insertedSoFar, total, skippedSoFar)
--   onSourceDone     function(name, inserted, skipped)
--   onComplete       function(results) — results = list of per-source rows
function Ledger:ImportFromAllSourcesChunked(opts)
  opts = opts or {}
  local sourceDelay = opts.sourceDelay or 0.5

  local results = {}
  local sourceIdx = 0

  local function nextSource()
    sourceIdx = sourceIdx + 1
    if sourceIdx > #sourceOrder then
      if opts.onComplete then pcall(opts.onComplete, results) end
      return
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

      self:InsertManyChunked(entries, {
        chunkSize = opts.chunkSize,
        delaySec = opts.delaySec,
        onProgress = function(inserted, total, skipped)
          if opts.onSourceProgress then pcall(opts.onSourceProgress, name, inserted, total, skipped) end
        end,
        onDone = function(inserted, skipped)
          results[#results + 1] = {
            source = name,
            inserted = inserted,
            skipped = skipped + parseSkipped,
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
      -- the open inbox; cheap regardless).
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
  TallyDB.ledger = {}  -- drop active blob + activeMeta + archives + archiveIndex
  _workingMem = defaultMem()
  _loaded = true
  _dirty = true
  if ns.Archive then ns.Archive:UnloadAll() end
end

-- Drop entries from a specific source across active + every archive.
-- Useful when an adapter changes its id scheme and we need to re-import
-- cleanly. Synchronous walk over archives is acceptable because this
-- is rarely-fired admin maintenance, but the cost scales with total
-- archive count — a future optimisation could defer archive rewrites
-- to the next seal cycle. Returns the number of entries removed.
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
  if removed > 0 then _dirty = true end

  if ns.Archive then
    for _, key in ipairs(ns.Archive:List()) do
      local archive = ns.Archive:Load(key)
      if archive and archive.entries then
        local archiveKept = {}
        local archiveRemoved = 0
        for _, e in ipairs(archive.entries) do
          if e.source == sourceName then
            archiveRemoved = archiveRemoved + 1
          else
            archiveKept[#archiveKept + 1] = e
          end
        end
        if archiveRemoved > 0 then
          if #archiveKept == 0 then
            ns.Archive:Delete(key)
          else
            ns.Archive:Save(key, archiveKept)
          end
          removed = removed + archiveRemoved
        end
      end
    end
  end

  return removed
end

-- Total row count across active + archives. Archive counts come from
-- the archive metadata (no blob loads required).
function Ledger:Count()
  local total = #db().entries
  TallyDB = TallyDB or {}
  local archives = TallyDB.ledger and TallyDB.ledger.archives or {}
  for _, rec in pairs(archives) do total = total + (rec.count or 0) end
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
