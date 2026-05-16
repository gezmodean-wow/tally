# Tally redesign — projection-layer architecture

**Status:** Design. Not yet implemented. Captures the redesign agreed with Gezmodean on 2026-05-16.
**Supersedes:** the alpha18/19 store-and-archive architecture, and the queued TLY-73 tab rework.
**Target:** alpha20 (teardown + new architecture), phased internally per the alpha cadence.

---

## 1. Why redesign

The alpha18/19 architecture (active blob + 60 archive slots + import controller + synthesis
engine) delivered correctness, but not the *view* Tally exists to provide. It also kept
fighting the Lua constant-pool wall by deferral — bigger active sets, more archive slots —
rather than removing it. This redesign removes the wall by removing the store.

## 2. Purpose of Tally (restated)

Tally exists to give a player:

- An accurate accounting of **net worth** and how it changes over time.
- An accurate accounting of the **distribution of their costs** — where the money goes.
- Tools to:
  - Understand the true **profit and loss** of the products they sell.
  - Look at their **realm sales / purchases** over time.
  - Understand **product values** over time.
  - Produce an **authoritative, deduplicated ledger** across all their data sources,
    exportable for offline analysis.

## 3. Core architectural shift

**Tally stops being a store of transactions and becomes a projection layer.** Siblings
(TSM Accounting, FlipQueue, Journalator) own the transaction data. Tally owns the
dedup/merge, the math, and the views. The unified ledger is a *computed artifact*, never a
saved one.

### 3.1 No native capture

Tally no longer captures AH / vendor / mail / repair events itself. It is fully dependent
on sibling sources for ledger data. Net worth still works without siblings (Syndicator
supplies inventory + gold) — so Tally-without-siblings is a net-worth tracker, and
Tally-with-siblings is the full ledger analysis suite.

- **Future option:** a separate, lightweight capture-only cog could be built and consumed
  as a library, for players who run no sibling accounting addon. Out of scope here; noted
  as a future cross-cog idea.

### 3.2 Storage model

Tally persists only data bounded by something *other than trade volume*:

1. **Net-worth snapshots** — a time series, bounded by time (≈ 1/day). Siblings cannot
   reconstruct this, so Tally must own it.
2. **Aggregates / summaries** — per-item P&L, per-realm rollups, operating-cost buckets,
   keyed by period. Bounded by items × periods × realms.
3. **Settings, appearance, and sparse manual dedup/merge overrides.**

Nothing Tally persists grows with row count → **the Lua constant-pool wall that haunted
alpha13/14/16/18 is structurally gone.**

### 3.3 Retired

- `TallyActive` SV (the active blob).
- `TallyA001`–`TallyA060` archive slot SVs.
- Archive LRU eviction (`Archive.lua`).
- The import controller — `Util/Import.lua`, `UI/ImportControl.lua`.
- The synthesis *write* path (`Util/Synthesis.lua` keeps its parser; drops archive writes).
- The setup wizard's import steps (Steps 4 + 5).

Retiring this is acceptable — nothing player-critical depends on the stored ledger today,
and alpha-tester data is expendable (no migration, no grandfathering).

### 3.4 Retained / promoted

- **Sibling adapters + `ProbeMetadata`** — now the *only* data source. Central.
- **The parse engines** — parsing stays; archive-writing goes.
- **TLY-69 multi-source gold authority** — feeds net-worth snapshots.
- **TLY-70 output taxonomy** (`ns.Output`).
- **Syndicator dependency** — net worth (inventory + gold).

### 3.5 The cost we accept

Detailed views compute by parsing sibling saved-variables on demand — the known 2–3s
TSM-CSV block. Mitigated by a **session-lifetime parse cache**: parse once per login,
recompute aggregates from the in-memory cache. Any view's window is bounded by the
**shortest-retaining source** — a player who keeps 30 days of TSM history gets 30 days.

### 3.6 Dedup is recompute-on-parse

Dedup is deterministic from entry content (item + timestamp + quantity + price +
counterparty), so it is **recomputed every parse, never stored** — which is what keeps the
per-row-growth wall gone. Only sparse manual overrides persist.

Dedup is really a **merge**: the same sale appears in multiple sources with different
fields (TSM has the AH cut; FlipQueue has post history; Journalator has mail). The unified
entry merges fields across sources. On conflict (TSM says 100g, FlipQueue says 99g): start
with the **simplest approach — flag for manual review** — and automate a resolution policy
later, once real conflict patterns are visible.

## 4. Navigation structure

Primary navigation is a **left bar**: `Live · Historical · Tools · Settings · Appearance`.

- **Live** — the recent / rolling window. Subtabs (Summary, Ledger, Research, …). No date
  picker; the window is implicit (recent, bounded by the shortest source).
- **Historical** — opens on a **date-range picker**. Once the player sets a range, it shows
  the same subtabs scoped to that range, with a **back arrow** returning to the picker.
- **Tools** — the exporter, plus any future tool surfaces (FlipQueue-style tools area).
- **Settings** — independent tab (FlipQueue pattern).
- **Appearance** — independent tab; adopts `cw:CreateAppearanceTab` (FlipQueue pattern).
  Deliberately kept separate from Settings for suite consistency.

Live and Historical **share the same subtab rendering** — they differ only in how the
window is determined. This replaces TLY-73's "global time-window navigator" with a
cleaner *section-determines-window* model.

## 5. Views (subtabs under Live / Historical)

### 5.1 Summary

- Net-worth graph over the active range, with multiple **configurable sparklines**.
- Key summary metrics.
- **Operating cost over time** — where the money is going.
- Best- and worst-performing products over the range.

### 5.2 Ledger

- The unified, deduplicated / merged ledger for the active window.
- Per-item and per-realm stats.
- Operating-cost breakdown for the period.
- Absorbs the old Compare tab's "Tally vs TSM" comparison, reframed as a **source-
  reconciliation facet** — what got merged, what is unique to each source.

### 5.3 Research

- **Navigable, not an empty search field** — seeded from items the player owns
  (Syndicator) or has seen (sibling sources within the active window).
- Expandable to **all known items**.
- Per-item value-over-time and P&L.

### 5.4 Lifecycle — removed from in-game scope

Per-lot object tracking (trace one specific stack: bought where, posted where, how many
failures, which realms) needs genuine per-entry detailed storage — exactly the thing this
redesign avoids to escape the memory limits. **Lifecycle is deferred to the future offline
pro service**, where detailed per-item storage is unconstrained. The in-game goal it
served — "help players see where items are costing them" — is partially covered by
Research's per-item P&L and the Summary operating-cost breakdown.

## 6. Minimap

- Configurable.
- **Default:** total net worth, broken down into gold / inventory / up-for-auction / owned
  (owned = the everything-included figure, distinct from saleable).
- Also shows the **saleable** figure.
- Optional trend data.
- Configurable quick-lookup stat slots.
- Configurable actions — default: left-click opens Tally, right-click prints a report
  (to a copy-dialog, not chat, per the output taxonomy).
- Supports **deep-linking** to individual tabs.

## 7. Multi-realm

Flipping is *always* multi-realm — the question is how many. Typical players trade 4–5
realms; some 10–20; some the whole region. Some run **dedicated buy realms vs sell
realms**. Implications:

- Every ledger entry carries a **realm dimension**.
- Per-realm stats distinguish **buy-side vs sell-side** activity, and can classify a realm
  as buy-dominant / sell-dominant.
- Region-wide commodity AH vs realm-specific gear: "realm" means different things for
  commodities vs equippable items — the realm model must handle both.

## 8. Export ("archives" reframed)

"Archives" are **no longer in-game saved-variable slots**. They are exported unified-ledger
files (CSV) the player keeps offline, or feeds to the future pro service. Optional: a
**scheduled-export reminder** so the player exports on a regular cadence. This aligns with
the portable-format direction and the pro-service plan.

## 9. Knock-on effects on existing issues / plans

- **TLY-73** (tab rework) — fully superseded. Part 1 (fold Lifecycle into Research) is moot;
  Lifecycle is removed. Part 2 (global navigator) is replaced by the Live/Historical split.
  Close in favour of the new umbrella.
- **TLY-24** (TSM-vs-Tally comparison) — reframed as the Ledger reconciliation facet.
- **TLY-66** (CSV-shaped slots) — partly moot (no slots), but CSV remains the export format.
- **FlipQueue migration** — *diverges from FlipQueue's documented plan.* FlipQueue's
  `TODO.md`/`CLAUDE.md` say its `ns.db.log` + SalesIndex move *into* Tally. Under this
  redesign FlipQueue's **data stays in FlipQueue permanently** and Tally adds an adapter;
  only FlipQueue's research *UI* migrates, not its store. This needs reconciling with the
  FlipQueue maintainer (cross-cog).

## 10. Open design details still to settle

- Exact subtab set under Live/Historical (Summary / Ledger / Research are confirmed; is
  per-realm its own subtab or a Summary section?).
- Conflict-resolution UX for the merge-review surface.
- Net-worth snapshot cadence (per login? per day? on demand?).
- Whether Live's implicit window is a fixed span (e.g. 60 days) or simply follows the
  shortest source.

## 11. Tester questions (for the feedback ticket)

1. How far back do you actually look at detailed transaction data — last week, last month,
   last quarter?
2. Do you do offline analysis of your AH data today? In what tool? What would you want in
   an export?
3. Which sibling addons do you run (TSM Accounting, FlipQueue, Journalator)? How long do
   you let TSM keep history?
4. When you think "profit on an item," do you think per-item-overall or per-individual-
   flip? Would you use a view that traces one specific stack's journey?
5. For net worth — do you care more about the *saleable* number or the *everything-owned*
   number, day to day?
6. What do you want one glance at the minimap to tell you?
7. How many realms do you trade? Do you separate buy realms from sell realms?
8. Would an occasional 2–3s load when opening a detailed view be acceptable, given it means
   Tally never bloats your saved-variables again?
