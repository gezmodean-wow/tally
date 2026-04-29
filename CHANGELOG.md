# Changelog

All notable changes to Tally will be documented in this file.

## [Unreleased]

- Historical net-worth replay (TLY-005):
  - Inventory snapshots now also record per-character (and warband) gold totals, so historical net-worth replay can sum gold + items at any past timestamp.
  - Inventory snapshot schema bumped from `[charKey] = { bags=N, ... }` to `[charKey] = { saleable, total, locations = { bags=N, ... } }`. The saleable/total pair preserves the bound-vs-saleable signal that per-location counts can't reconstruct alone. Pre-bump snapshots upgrade lazily on read; saleable defaults to total for legacy data (slight over-count on pre-migration data, corrects forward).
  - New `History:GetNetWorthAt(atTime, opts)` reconstructs net worth at any past time using the nearest-prior inventory snapshot for counts/gold and the nearest-prior pricing snapshot for unit values. Returns the same shape as `NetWorth:Snapshot()` plus `atTime` and `pricedAt` markers. `opts.includeBound` switches between net (saleable) and owned (incl. bound) views.
  - New slash form: `/tally networth at -<duration>` and `/tally ownedworth at -<duration>`. Duration accepts `-7d`, `-1h`, `-30m`, `-1w`, etc. Output prints the historical snapshot plus `Δ vs now` line with absolute and percentage delta.
  - `_G.TallyAPI` bumped to v1.3: adds `GetNetWorthSnapshotAt(atTime, opts)`. `GetNetWorthSnapshot` now accepts an `opts` argument (additive).
- Adopted Cogworks v0.10.0 (TLY-003):
  - `.pkgmeta` external bumped to `v0.10.0`; TOC now loads `Libs\Cogworks-1.0\Cogworks-1.0.xml` to pick up the multi-file manifest (Items / Realms / API / Icons / Sections).
  - Minimap registration goes through `Cogworks:RegisterCogMinimapButton`, which hides LDBIcon's default tracking border and mounts the suite-shared brass gear ring around our inner glyph. Soft-degrades to a plain `LDBIcon:Register` on older Cogworks.
  - Removed local `Art/CogBorder.tga`; the gear texture now ships with the Cogworks lib at `Libs/Cogworks-1.0/Art/CogBorder` and is resolved by the helper.
- History substrate — pricing + inventory time series (foundation for TLY-002):
  - New root `History.lua` records two parallel time series at the same cadence: per-itemID prices under the active strategy (strategy-keyed) and per-itemID per-character per-location inventory counts. Snapshots fire on first `InventoryChanged` per session (debounced) and on demand via `/tally history snapshot`.
  - Inventory history captures per-character resolution: each snapshot's items map records `{ [itemID] = { [charKey] = { bags=N, reagent=N, bank=N, mail=N, equipped=N, void=N, auctions=N, warbank=N } } }` with only non-zero locations stored. The synthetic `Warband` charKey carries warbank counts.
  - Pricing history records TSM and WoW Token unit values; vendor and unpriced lookups are excluded. Recorded values follow the active strategy and are kept under separate strategy keys so switching strategies preserves prior history.
  - Shared two-stage retention: configurable max-age window plus a daily-rollup threshold that collapses older snapshots to one-per-day. Defaults: 6h interval, 365d retention, daily rollup past 30d.
  - User-configurable from chat: `/tally history` (summary + config), `/tally history interval <hours>` (0 disables auto-snapshot), `/tally history retention <days>`, `/tally history rollup <days>`, `/tally history clear [strategy]`. Config is shared across both series — one knob controls both.
  - `/tally research <item>` now surfaces a Price-history line (snapshot count, span, 7d/30d Δ%) and an Inventory-history line (snapshot count, 7d/30d delta total with top-3 per-character breakdown when multiple characters moved).
  - `_G.TallyAPI` bumped to v1.2: adds `GetItemPriceHistory`, `GetItemPriceTrend`, `GetItemInventoryHistory`, `GetItemInventoryTrend` for sibling cogs.
- Owned-worth completeness (TLY-001):
  - `Inventory/Ownership.lua` now folds Syndicator's `equipped`, `void`, and `auctions` slot lists into the per-character rollup, with new `location` enum values for each.
  - Active AH auctions count as saleable regardless of `isBound` — they're being sold by definition — via an `isSlotSaleable(slot, itemID, location)` override. They contribute to both net worth and owned worth.
  - Equipped gear and void storage default to bound, so they only contribute to owned worth (matches existing saleable/bound split).
  - Added `AuctionsCacheUpdate` callback so AH posts/cancels trigger a rescan.
  - `/tally research` Locations line now surfaces a per-location breakdown (e.g. `Hugemane-Stormrage ×1 [equipped ×1]`) so equipped/void/auction visibility is verifiable.
- Initial scaffold via `/cog-init tally --ldb`.
- Filled in addon description (TOC, README, CLAUDE.md): Personal Capital for WoW.
- Phase 3 — net worth + inventory rollup:
  - `Pricing/Sources.lua` — TSM adapter (configurable strategy, default `DBRegionMarketAvg`) with WoW Token special-case and vendor-price fallback when TSM is absent.
  - `Inventory/Ownership.lua` — Syndicator-driven per-character + warband rollup, refreshed on `BagCacheUpdate` / `WarbandBankCacheUpdate`.
  - `NetWorth/Calculator.lua` — strategy-driven snapshot summing gold + items + tokens across all known characters and the warband.
  - LDB launcher now displays running net-worth total; tooltip breaks down by source.
  - Slash commands: `/tally networth`, `/tally rescan`, `/tally strategy [expr]`.
- Phase 1 — item research:
  - `Research/Aggregator.lua` — per-item record (strict superset of FlipQueue's `ItemResearch` shape) covering ownership, multi-source pricing snapshot, valuation, and (when FlipQueue is present) sales/failures/active-auctions/purchases pulled read-only from `FlipQueueDB.log`.
  - `_G.TallyAPI` (v1.0) exposes `GetItemResearch`, `InvalidateItemResearch`, `GetNetWorthSnapshot`, `GetInventoryRollup`. Versioned stopgap until Cogworks issue #6 lands a native API registry.
  - Slash command: `/tally research <itemlink-or-id>`.
- Fixes (post initial smoke-test):
  - `Util/Items.lua` — lifted FlipQueue's canonical `ParseItemLink` + `MakeItemKey` so Tally's rollup and research lookups produce identical keys, and battle-pet links resolve correctly. Deletable once cogworks#6 lands and Cogworks owns these helpers.
  - `Inventory/Ownership.lua` — rewrote container walker to match FlipQueue's `Scanner.lua` patterns: bags `[1..5]` flat slot arrays, bank tabs with `tab.slots or tab` heuristic, warband bank with the same heuristic. Warband items now actually appear in the rollup.
  - `Research/Aggregator.lua` — link normalization uses `Util/Items` so links match rollup keys; bare item IDs aggregate across bonus-ID variants; pet records skip TSM pricing; chat output now lists per-character/warband locations so warband visibility is verifiable.
- Net worth = saleable items only:
  - Inventory rollup tracks both `total` and `saleable` counts per item (saleable = Syndicator's `isBound` flag is false; WoW Tokens are special-cased as always saleable).
  - `NetWorth:Snapshot()` defaults to saleable-basis. `Snapshot({ includeBound = true })` returns the owned-worth view.
  - `/tally ownedworth` (alias `/tly ow`) prints the owned-worth view alongside `/tally networth` for the saleable view.
  - LDB tooltip surfaces both — header reads "net worth (saleable items only)" with a separate "Owned worth (incl. bound)" line.
  - Research record adds `saleableInventory` and `valuation.ownedWorthContribution`; `valuation.netWorthContribution` is now strictly saleable. `totalInventory` keeps its FlipQueue-compatible meaning (everything owned).
