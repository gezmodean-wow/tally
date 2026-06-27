# Tally — next session handoff

alpha19 shipped 2026-05-14. The active workstream is the **projection-layer redesign** (umbrella #77). The data spine + persistence are complete, **the alpha18/19 store has been torn down (#78)**, and the **new navigation + Summary/Ledger views (#83–#86) have landed**. Remaining on the #77 critical path: **#87 (Research view), #88 (minimap), #89 (Tools/CSV export)**.

## State

- **Branch:** `main`. **9 commits ahead of `origin/main`, unpushed.** Push needs explicit approval.
- **Latest tag:** `v0.1.0-alpha19`, shipped 2026-05-14. alpha20 not yet tagged.
- **Interface:** `tally.toc` bumped **`120001` → `120007`** (CF-12 suite-wide bump for the new WoW client build, commit `4add4a4`). Held at the human release gate — not pushed/tagged. CF-12 lives in the **chronoforge** repo (#12) and was never mirrored into Tally's tracker.
- **Cogworks pin:** `.pkgmeta` external bumped **`v0.14.2` → `v0.16.0`** (commit `e8cc14c`). Local `Libs/Cogworks-1.0/` (gitignored/package-time) **re-extracted to v0.16.0** for in-game testing. The bump clears the `CreateAppearanceTab` empty-tab bug (COG-75, fixed v0.14.3) that left #72 on the fallback path.
- **Standards acknowledgments:** runbooks `2026-05-05a`, scribe player-facing `2026-04-30f`. The player-facing doc was WebFetched 2026-05-17 — top changelog entry still `2026-04-30f`, no update needed.
- **⚠️ Nothing since the spine is smoke-tested in-game.** The whole spine + #81 + #82 + the #78 teardown + the #83–#86 views are syntax-checked only (`luac -p`). The teardown is large and destructive, and the new views/interface/lib bumps are all unverified — an in-game pass is the most urgent next step before any further build-out (see Loose ends).

## Done 2026-06-07 — #82 aggregates + #78 teardown

- **`74cbd39` feat(TLY-82)** — `Spine/Aggregates.lua`: period-keyed (`YYYY-MM`) rollups (per-item P&L, per-realm buy/sell, operating-cost buckets) recomputed wholesale from `UnifiedLedger:Query({})` via a hook in `ParseCache.finish()`. Bounded by period × item × realm; `/tally spine` reports it.
- **`8ce0d3d` refactor(TLY-78)** — retired the alpha18/19 store. **Maximal teardown** (user-directed): removed `TallyActive` + `TallyA001..A060`, `Archive.lua`, `Util/Import.lua` + `UI/ImportControl.lua` + `UI/SynthButton.lua`, the synthesis write-path (parser kept), **native capture** (`Sources/Native*`), and the **old view pages** (NetWorth/Research/Lifecycle/Ledger/Compare) + their seal UI. **`Ledger.lua` reduced ~2900→~530 lines** to a lean core: Kinds/Schema/BuildUnknownEntry/Authority/GetAuthority + source registry + `IsSetupComplete`/`Clear`; `Reconcile`/`Query`/`Stats` are now thin **shims over `Spine/UnifiedLedger`** so the Cogworks public API + Research keep working on spine data. Schema bump v18→v19 = clean-break wipe. SetupWizard reduced to Welcome+Strategy; Settings "Import now"→"Re-parse". `Sources/*` standalone (getEntriesFn only). All live Lua `luac -p` clean; TOC↔FS verified; no dangling refs.

**Decisions captured** (forks the user resolved during #78): remove seal/migration now; remove native capture now; remove old view pages now. Research/Aggregator + Research/Lifecycle were **kept** (they back the Cogworks `GetItemResearch`/`GetItemLifecycle` API) and now read spine data through the `Reconcile` shim. `InventoryPage` kept (Syndicator-based, works standalone) so one content tab survives alongside Spine/Settings/Appearance.

## The redesign — read this first

**`docs/REDESIGN.md` is the canonical design.** Tally stops being a *store* of transactions and becomes a *projection layer* over sibling sources: no native capture, no stored ledger, recompute-on-parse dedup/merge, persists only net-worth snapshots + aggregates + sparse manual overrides.

GitHub: **[#77](https://github.com/gezmodean-wow/tally/issues/77)** umbrella (14-item checklist) · task issues **[#78](https://github.com/gezmodean-wow/tally/issues/78)–[#90](https://github.com/gezmodean-wow/tally/issues/90)** + **[#72](https://github.com/gezmodean-wow/tally/issues/72)**.

## Done this session — the data spine (4 commits)

The architecture was planned first (Plan agent), then built as **additive** modules under a new `Spine/` directory — nothing in the live addon changed behaviour. All five commits syntax-check clean (`luac -p`). The only player-visible surfaces are the `/tally spine` diagnostic and the (default-off) Spine verification tab.

- **`f2032c0` feat(TLY-80) — dedup/merge pure core.** `Spine/Dedup.lua` (`ns.Spine.Dedup`): pure recompute-on-parse dedup/merge — coarse-key bucketing (`kind|itemID|charKey|count|counterparty`) + windowed clustering with the source-uniqueness gate ported from `Ledger.clusterGroup`, so distinct same-source events never collapse. **Price is a tolerance-gated match constraint, not a key field** — keying on exact price would split the records whose prices conflict and hide the conflict; instead near-prices merge and flag, far-apart prices stay distinct (user-confirmed design call). Field-merge reuses `ns.Ledger:GetAuthority`. `Spine/Overrides.lua` (`ns.Spine.Overrides`): the one persisted piece — sparse manual corrections in a new `TallyDB.merge` sub-key, keyed on relog-stable `Dedup.entryKey`.
- **`18cf1fc` feat(TLY-79) — session parse cache.** `Spine/ParseCache.lua` (`ns.Spine.ParseCache`): parses each sibling source once per session via its `getEntriesFn`, chunked one-source-per-tick, `generation`-guarded. **Lazy, not login-eager** — deliberately NOT hooked into `PLAYER_LOGIN` (an unconditional login parse would re-create the flipper-loop relog tax the alpha18 rewrite removed); populates on first demand. `TallyDB.spine.enabled` escape-hatch flag, default on. New `/tally spine` slash command (`parse`/`status`/`on`/`off`).
- **`6619aff` feat(TLY-80) — projection API.** `Spine/UnifiedLedger.lua` (`ns.Spine.UnifiedLedger`): the read surface views call — `Query(filter)`, `GetReviewList()`, `Stats(filter)`, `IsReady()`. Memoized recompute, invalidated when the parse cache refreshes. **Realm dimension (#90)**: every record gains `realm = { key, side }` (key from the charKey, normalized via Cogworks; side buy/sell/neutral from kind).
- **`e4482cf` feat(TLY-79) — parse loading bar.** `UI/ParseProgress.lua`: listener on `ParseCache` rendering the parse via `ns.UI.CreateProgressBar`. Satisfies the #76 Q8 requirement (2-3s parse OK only if a loading bar shows).
- **`3867469` feat(TLY-77) — verification tab.** `UI/SpinePage.lua` (`ns.UI.CreateSpinePage`): gated debug tab (`TallyDB.ui.showSpineTab`, default off, new Settings toggle), renders `UnifiedLedger:Query` / `GetReviewList` in a scroll table so the spine can be diffed against the live `LedgerPage`. **`OnShow` is the lazy-parse trigger** — calls `ParseCache:Ensure()`.

**Data flow now in place:** `ParseCache → Dedup → Overrides → realm dimension → UnifiedLedger:Query`. Verify in-game with `/tally spine parse`, or enable the Spine tab in Settings.

## Done this session — net-worth snapshot store (#81, complete)

#81 was planned (Plan agent — full design in the session) and built in two commits:

- **`f83531d` feat(TLY-81)** — `Spine/NetWorthStore.lua` (`ns.Spine.NetWorthStore`): net-worth time series in `TallyDB.networth_snapshots`, one bounded row per calendar day (180-day retention), `capture()` runs net + owned valuations, `byRealm` fold. Cadence wired into `InventoryChanged`; `GetSeries` repointed the net-worth chart. `History.lua` still loaded.
- **`64c5094` refactor(TLY-81)** — `History.lua` deleted. Orphaned `TallyDB.history`/`pricingHistory` dropped via a targeted nil (not a schema bump — that would re-wipe the live ledger, #78's job). `Core.lua` `GetNetWorthAt` consumers repointed to `NetWorthStore:GetAt`; `/tally history` reworked; `SettingsPage` "History cadence" → retention-only; `SetupWizard` history step removed. `Research/Aggregator`'s per-item price/inventory-history calls are `ns.History`-guarded — they no-op cleanly; Research's value-over-time returns with **[#91](https://github.com/gezmodean-wow/tally/issues/91)** (filed this session — bounded `Spine/PriceHistory.lua`).

## Done 2026-06-26 — the new navigation + views (#83–#86)

- **`4c5ffa3` feat(TLY-83/84)** — left-bar `Live · Historical · Tools · Settings · Appearance` nav shell (REDESIGN §4) + Historical date-range picker. Live + Historical share subtab rendering; they differ only in how the window is set.
- **`5238be4` feat(TLY-85)** — Summary view: net-worth chart, headline metrics, operating-cost + product breakdowns, projected over the `UnifiedLedger`/`Aggregates`/`NetWorthStore` spine APIs.
- **`b92b619` feat(TLY-86)** — Ledger view: windowed unified ledger + reconciliation over `UnifiedLedger:Query`. Absorbs #24 (TSM-divergence reframe) and the #90 realm dimension.

## Next work — Research view + minimap + tools

Per the #77 order, persistence (#81/#82), the teardown (#78), and the nav + Summary/Ledger views (#83–#86) are done. What remains: **#87 (Research view)** → **#88 (minimap rework)** → **#89 (Tools/CSV export)**. Content tabs now live: **Live** (Summary/Ledger) + **Historical**, plus **Inventory**, the gated **Spine** verification tab, **Settings**, **Appearance**.

- **#87 next** — the Research view is the last major projection. `Research/Aggregator` + `Research/Lifecycle` already read spine data via `Ledger:Reconcile` → `UnifiedLedger:Query`; #87 gives them in-game UI. Per-item value-over-time lands with **#91** (bounded `Spine/PriceHistory.lua`). Cross-toon flip P&L (toeknee Q4) is a Research-view capability the unified ledger can support.
- **#90 (multi-realm)** is partly delivered (the `realm` dimension on every unified record); the remainder — per-source realm accuracy (FlipQueue `targetRealm`), connected-realm `group` rollup — threads through #86.
- **Research return** — `Research/Aggregator` + `Research/Lifecycle` now read spine data via `Ledger:Reconcile` → `UnifiedLedger:Query`. They're wired to the Cogworks API but have **no in-game UI** until #87. Per-item value-over-time returns with **#91** (bounded `Spine/PriceHistory.lua`).

## Loose ends

- **🔴 In-game smoke test is now the top priority.** The #78 teardown plus the #83–#86 views, the `120007` interface bump, and the Cogworks v0.16.0 lib bump are all unverified in-game. First checks: addon loads without Lua error on a `120007` client; `/tally` opens the new left-bar shell (**Live → Summary/Ledger**, **Historical**, Inventory, Settings, Appearance); enable the Spine tab → `/tally spine parse` shows the loading bar + non-zero record count + aggregates line; the setup wizard (Welcome+Strategy) completes; `/tally reset confirm` works; `/tally diag` dumps cleanly. The schema bump (v19) wipes the old store on first login — expected.
- **#72 should now render for real** — the local lib is v0.16.0, so the Appearance tab exercises the fixed `CreateAppearanceTab` (COG-75) + the full color editor (COG-73), not the empty-tab fallback. Verify in the smoke test.
- **CF-12 not mirrored into Tally's tracker** — the interface bump came from chronoforge#12; no `TLY` issue exists for it. File one (or close-loop on the umbrella) if you want it tracked locally.
- **Check `- [x] #72` and `- [x] #78` on the #77 umbrella checklist** — need `gh` remote writes (approval).
- **Stale doc references** — `CLAUDE.md` repo-layout and `docs/REDESIGN.md` still describe `Sources/Native`, `Archive.lua`, etc. as present. Cosmetic; refresh when convenient.

## Tester feedback (#76)

Both testers have replied (**zong and _zpectre_ are the same person** — no third reply pending).

- **toeknee** — runs TSM + FlipQueue (TSM keeps 1yr); looks back ~30d; net worth = everything-sellable + all gold; **84 buy realms / 25 sell realms**; minimap wants gold (toons/warbank/GB) + items (toons/AH/warbank) + grand total; 2-3s parse pause OK **if a loading bar shows** (drove `UI/ParseProgress.lua`). Wants cross-toon flip tracking — "bought on one toon, sold on another," a TSM gap.
- **zpectre** — runs **FlipQueue + Journalator, no TSM** (the TSM-less test case — the spine handles it: `ParseCache` parses only available sources, `Dedup` falls through `Ledger`'s `DEFAULT_PRIORITY`); looks back "a few weeks"; net worth without bound items (= saleable); profit as a **%**, avg-per-item + overall-per-item; minimap wants total net worth + total gold; trades **52 realms**, buys and sells on all.

**Both testers confirm Q8** (2-3s parse acceptable). **Both look back only a few weeks** → the implicit Live window (#84) can be short, not 60 days. Cross-toon flip P&L (toeknee Q4) is a Research-view (#87) capability the unified ledger can support — worth a note on #87. There is no third tester pending — **zong and _zpectre_ are the same person** — so #76 feedback is as complete as it will get; the build-out plan can be locked.

## alpha cadence

Multi-alpha. alpha20 ≈ teardown + data spine; views land across alpha20–22. Phase internally via commits, tag once. Tester data is expendable — clean break, no migration.

## Live testers

Two testers, not three — **zong and _zpectre_ are the same person**.

- **Toeknee_atx** (68 chars) — runs TSM + FlipQueue.
- **_zpectre_** (also posts as **zong**; TLY-65 is his) — runs FlipQueue + Journalator, no TSM.

## Open issues snapshot

- **#77** umbrella · **#76** feedback · **#87, #88, #89, #72** remaining tasks. **#78–#86 are code-complete** (spine core, persistence, aggregates, teardown, nav shell, Summary/Ledger views); **#79–#86 can be closed** once an in-game smoke test passes. #72 (Appearance tab) is code-complete and unblocked by the v0.16.0 bump.
- **#73** tab rework — close (superseded by #77).
- **#24** → reframed into #86 · **#66** → reframed into #89 · **#65** zpectre divergence — was native-vs-sibling; **moot under projection** (no native capture). Revisit as a source-reconciliation facet of the Ledger view (#86) or close.
- **#69 / #70 / #71 / #68** — alpha19 shipped fixes; close after tester confirmation. **Note #71** (manual import controller) is **superseded by #78** — the import controller it built was removed; close as superseded.
