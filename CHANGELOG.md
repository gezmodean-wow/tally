# Changelog

All notable changes to Tally will be documented in this file.

## [Unreleased]

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
