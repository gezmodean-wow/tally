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
