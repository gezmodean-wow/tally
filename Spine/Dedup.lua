-- Tally — Spine/Dedup.lua
--
-- Pure dedup/merge core for the projection-layer redesign (TLY-80).
--
-- The data spine treats sibling addons (TSM, FlipQueue, Journalator, the
-- old Native source) as the owners of transaction data. Tally never stores
-- a ledger; it recomputes a unified, deduplicated ledger from the parsed
-- sibling rows every time it parses. This module is that recompute — and
-- nothing else. It is intentionally pure: it takes a flat list of ledger
-- entries (the entry shape documented in Ledger.lua) and returns unified
-- records. No SavedVariables, no events, no globals.
--
-- This is the spine sibling of Ledger.lua's Reconcile pass. Reconcile
-- operates over rows already inserted into the stored ledger; Dedup
-- operates over the in-memory parse cache and is what survives once the
-- store is retired (TLY-78). The Authority / per-field provenance machinery
-- is reused from ns.Ledger rather than duplicated.
--
-- ── Dedup is a merge ────────────────────────────────────────────────────
-- The same real-world sale shows up in several sources with different
-- fields: TSM knows the post-cut copper, FlipQueue knows the posting
-- history, Journalator knows the mail. Dedup groups those observations and
-- merges their fields into one unified record with per-field provenance.
--
-- ── What stops distinct events collapsing ───────────────────────────────
-- The source-uniqueness gate. A cluster holds at most one row per source,
-- so two purchases recorded by the *same* addon never merge into each
-- other — each adapter is the authoritative deduper of its own rows, so
-- two TSM rows are two real events. Buying five identical stacks shows as
-- five records. Merging only ever pairs observations *across* sources.
--
-- ── Where price fits (TLY-80 design note) ───────────────────────────────
-- Issue #80 lists price in the dedup key. Keying on exact price is
-- self-defeating: it would split the very records whose prices disagree
-- (TSM 100g vs FlipQueue 99g) and so hide the conflict instead of
-- surfacing it. Price is therefore a *tolerance-gated match constraint*,
-- not a key field:
--   * prices within the merge band  → same event → merge (flag if unequal)
--   * prices outside the merge band → distinct events → never paired
-- This keeps genuinely-different buys at different prices apart while
-- still merging one real sale that two sources priced slightly differently.

local addonName, ns = ...

ns.Spine = ns.Spine or {}

local Dedup = {}
ns.Spine.Dedup = Dedup

-- ── Tuning constants ────────────────────────────────────────────────────
-- These are deliberately exposed on the module so /tally diag and future
-- tuning can read and adjust them. The starting values mirror Ledger's
-- Reconcile pass; they need validation against real tester data (toeknee's
-- 84-realm dataset is the stress case) — see TLY-79/80 open questions.

-- Two cross-source observations are candidates for the same event only if
-- their timestamps fall within this window. Sources timestamp the "same"
-- sale differently (TSM logs CSV-write time, Journalator logs mail-receipt
-- time, FlipQueue logs soldAt), so an exact-second match would never fire.
Dedup.MERGE_WINDOW = 5 * 60  -- 5 minutes, matches Ledger's RECONCILE_WINDOW

-- Price merge band. Two copper amounts are "the same event's price" if
-- they differ by no more than max(ABS floor, REL fraction of the larger).
-- Inside the band the rows merge; outside it they are treated as distinct
-- events and never paired. The band is generous enough to absorb a genuine
-- cross-source recording discrepancy (rounding, cut-inclusion differences)
-- without coalescing two unrelated trades that happen to share every other
-- key field within the window.
Dedup.PRICE_MERGE_REL = 0.15   -- 15%
Dedup.PRICE_MERGE_ABS = 100    -- 1 silver — floor for very small amounts

-- Fields merged per record via Authority. id/kind/charKey/itemID drive the
-- grouping; atTime/copper/count/itemKey are picked per-field from the
-- highest-priority source. Mirrors Ledger.lua's RECONCILED_FIELDS.
local RECONCILED_FIELDS = { "atTime", "copper", "count", "itemKey" }

-- Numeric fields checked for cross-source conflict. count is part of the
-- coarse key (constant within a cluster) so only copper can actually
-- diverge; the list is kept general for future fields.
local CONFLICT_FIELDS = { "copper" }

-- ── Field extractors ────────────────────────────────────────────────────

-- The counterparty of a transaction, when a source records one. TSM
-- carries the AH/trade partner as meta.otherPlayer; Journalator trades
-- carry meta.partner. Absent (anonymous commodity sales, most kinds) it
-- simply returns "" and so does not constrain the coarse key.
local function counterparty(e)
  local m = e.meta
  if type(m) ~= "table" then return "" end
  return m.otherPlayer or m.partner or ""
end

-- The coarse bucket key for an entry: kind + item + character + quantity +
-- counterparty. Rows sharing a coarse key are *candidates* to be the same
-- event; the windowed + source-unique + price-band pass inside cluster()
-- decides which candidates actually merge.
--
-- charKey ("Name-Realm") is in the key because a single ledger entry
-- belongs to one character — and so encodes the realm dimension (TLY-90)
-- the way every source already records it. Two characters trading the
-- same item must not merge.
--
-- Unknown rows (Ledger.Kinds.Unknown) never merge — each carries a
-- distinct sourceKind whose diagnostic value a merge would lose — so their
-- key folds in the unique entry id, putting every Unknown in its own
-- single-row cluster.
function Dedup.coarseKey(e)
  if e.kind == "unknown" then
    return "unknown|" .. tostring(e.id or e.sourceId or e)
  end
  return table.concat({
    e.kind or "?",
    tostring(e.itemID or 0),
    e.charKey or "?",
    tostring(e.count or 1),
    counterparty(e),
  }, "|")
end

-- A stable identity string for a unified record, derived from the sorted
-- original entry ids it merged. Stable across re-parses as long as the
-- underlying source rows are stable (adapters hash on canonical row
-- identity), so a sparse manual override keyed on it survives a relog.
-- This is the key Spine/Overrides.lua stores against.
function Dedup.entryKey(record)
  local ids = record.originalIds or {}
  if #ids == 0 then return "u:" .. tostring(record.id or "?") end
  local copy = {}
  for i = 1, #ids do copy[i] = tostring(ids[i]) end
  table.sort(copy)
  return "u:" .. table.concat(copy, "+")
end

-- ── Price band ──────────────────────────────────────────────────────────

-- True if two copper amounts are close enough to be the same event's
-- price. A nil on either side cannot disprove a match, so it passes — the
-- source simply did not record copper for that row.
function Dedup.pricesMergeable(a, b)
  if a == nil or b == nil then return true end
  local hi = math.max(math.abs(a), math.abs(b))
  local tol = math.max(Dedup.PRICE_MERGE_ABS, Dedup.PRICE_MERGE_REL * hi)
  return math.abs(a - b) <= tol
end

-- ── Clustering ──────────────────────────────────────────────────────────

-- Group a flat list of entries into clusters, each cluster being the set
-- of cross-source observations of one real-world event.
--
-- Two-stage: bucket by coarseKey, then within each bucket run a greedy
-- windowed pass. A row joins the first existing cluster whose lead row is
-- within MERGE_WINDOW, does not already hold a row from this row's source,
-- and whose price is within the merge band; otherwise it opens a new
-- cluster. The source-uniqueness gate is what keeps distinct same-source
-- events apart (see file header).
function Dedup.cluster(entries)
  local buckets, order = {}, {}
  for _, e in ipairs(entries) do
    local k = Dedup.coarseKey(e)
    local b = buckets[k]
    if not b then b = {}; buckets[k] = b; order[#order + 1] = k end
    b[#b + 1] = e
  end

  local clusters = {}
  for _, k in ipairs(order) do
    local rows = buckets[k]
    table.sort(rows, function(a, b) return (a.atTime or 0) < (b.atTime or 0) end)

    local open, openSources = {}, {}
    for _, e in ipairs(rows) do
      local src = e.source or "?"
      local matched
      for i, cluster in ipairs(open) do
        local lead = cluster[1]
        if not openSources[i][src]
           and math.abs((e.atTime or 0) - (lead.atTime or 0)) <= Dedup.MERGE_WINDOW
           and Dedup.pricesMergeable(e.copper, lead.copper) then
          cluster[#cluster + 1] = e
          openSources[i][src] = true
          matched = true
          break
        end
      end
      if not matched then
        open[#open + 1] = { e }
        openSources[#open] = { [src] = true }
      end
    end

    for _, cluster in ipairs(open) do
      clusters[#clusters + 1] = cluster
    end
  end
  return clusters
end

-- ── Merge ───────────────────────────────────────────────────────────────

-- For one cluster, pick a field from the highest-priority source that has
-- a non-nil value, falling back to the first row's value in cluster order.
-- Returns value, sourceName.
local function pickField(cluster, kind, field)
  local priority = ns.Ledger:GetAuthority(kind, field)
  for _, srcName in ipairs(priority) do
    for _, e in ipairs(cluster) do
      if e.source == srcName and e[field] ~= nil then
        return e[field], srcName
      end
    end
  end
  for _, e in ipairs(cluster) do
    if e[field] ~= nil then return e[field], e.source end
  end
  return nil, nil
end

-- Detect cross-source disagreement on a numeric field. Returns a
-- { [source] = value } map if two or more sources gave differing values,
-- or nil if they agree (or only one source supplied the field).
local function fieldConflict(cluster, field)
  local seen, distinct, count = {}, nil, 0
  for _, e in ipairs(cluster) do
    local v = e[field]
    if v ~= nil and seen[e.source or "?"] == nil then
      seen[e.source or "?"] = v
      count = count + 1
      if distinct == nil then
        distinct = v
      elseif v ~= distinct then
        distinct = false  -- sentinel: at least two differing values
      end
    end
  end
  if count >= 2 and distinct == false then return seen end
  return nil
end

-- Merge a cluster into one unified record with per-field provenance,
-- merged meta, a contributing-sources set, and a conflict surface.
--
-- Ported from Ledger.lua's buildReconciledRecord — the field-pick and
-- meta-merge logic is the same; the additions are the conflict scan and
-- the review flag that drive the flag-for-review list (TLY-80).
function Dedup.merge(cluster)
  local kind    = cluster[1].kind
  local charKey = cluster[1].charKey
  local itemID  = cluster[1].itemID

  local rec = {
    kind        = kind,
    charKey     = charKey,
    itemID      = itemID,
    sources     = {},
    originalIds = {},
    provenance  = {},
  }
  for _, e in ipairs(cluster) do
    rec.sources[e.source or "?"] = true
    rec.originalIds[#rec.originalIds + 1] = e.id
  end

  for _, field in ipairs(RECONCILED_FIELDS) do
    local v, from = pickField(cluster, kind, field)
    rec[field] = v
    rec.provenance[field] = from
  end

  -- Meta: shallow merge in atTime-authority order so higher-priority
  -- sources' keys win and lower-priority sources fill the gaps.
  rec.meta = {}
  rec.metaProvenance = {}
  local metaOrder = ns.Ledger:GetAuthority(kind, "atTime")
  local visited = {}
  for _, srcName in ipairs(metaOrder) do
    for _, e in ipairs(cluster) do
      if e.source == srcName and not visited[e] and type(e.meta) == "table" then
        visited[e] = true
        for mk, mv in pairs(e.meta) do
          if rec.meta[mk] == nil then
            rec.meta[mk] = mv
            rec.metaProvenance[mk] = e.source
          end
        end
      end
    end
  end
  for _, e in ipairs(cluster) do
    if not visited[e] and type(e.meta) == "table" then
      for mk, mv in pairs(e.meta) do
        if rec.meta[mk] == nil then
          rec.meta[mk] = mv
          rec.metaProvenance[mk] = e.source
        end
      end
    end
  end

  -- Representative source: whichever source won the atTime pick — the
  -- "primary observer" for consumers that want a single source string.
  rec.source = rec.provenance.atTime or (cluster[1] and cluster[1].source)

  -- Conflict scan. The merged value (the Authority pick above) is always
  -- kept so totals never block on a human; a conflict only annotates the
  -- record and routes it to the flag-for-review list.
  for _, field in ipairs(CONFLICT_FIELDS) do
    local conflict = fieldConflict(cluster, field)
    if conflict then
      rec.conflicts = rec.conflicts or {}
      rec.conflicts[field] = conflict
      rec.review = true
    end
  end

  rec.id = Dedup.entryKey(rec)
  return rec
end

-- ── Top-level ───────────────────────────────────────────────────────────

-- Cluster + merge a flat entry list into unified records. Returns the
-- record list and a summary table (counts of inputs, records, merged
-- multi-source records, and records flagged for review) for /tally diag.
function Dedup.run(entries)
  local clusters = Dedup.cluster(entries)
  local records = {}
  local summary = { entries = #entries, records = 0, merged = 0, review = 0 }
  for _, cluster in ipairs(clusters) do
    local rec = Dedup.merge(cluster)
    records[#records + 1] = rec
    summary.records = summary.records + 1
    if #cluster > 1 then summary.merged = summary.merged + 1 end
    if rec.review then summary.review = summary.review + 1 end
  end
  return records, summary
end
