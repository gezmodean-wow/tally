# Tally — next session handoff

Picks up after the 2026-05-04 session. Last shipped: `v0.1.0-alpha8` — Phase 1 of the authoritative-ledger bundle (TLY-36 / 37 / 38) plus tester-feedback fixes (TLY-40 / 41 / 42 / 43 / 44) and the cogworks verify-package CI gate.

## State

- Working tree clean. Alpha8 commits + tag pushed; release CI run 25305999998 succeeded after a TOC forward-slash fix (the cogworks verify script can't resolve backslash separators on Linux — workaround landed in tally, proper fix tracked at [cogworks#29](https://github.com/gezmodean-wow/cogworks/issues/29)).
- Cogworks pinned at `v0.13.1` in `.pkgmeta`; vendored `Libs/Cogworks-1.0/` synced (gitignored).
- 11 stale issues (TLY-13/14/15/16/19/21/22/23/25/26/27) bulk-closed with player-update comments since they shipped in alpha2/alpha3 already. TLY-20 + TLY-32 got retest-request comments (likely already-fixed but need tester confirmation on alpha7+).
- Memory at `C:\Users\gezmo\.claude\projects\C--src-tally\memory\` is current.

## Cadence rule

Per saved `feedback_alpha_cadence.md`: **alphas ship full critical-path bundles, not incremental planned work.** Subsequent alphas exist only to fix tester-reported problems. Phase the development internally across sessions / commits, but only `git tag` when the bundle is complete.

Alpha8 was a partial-bundle exception: shipped Phase 1 + tester polish per direct user direction so testers could validate the data-quality work and cycle on the polish fixes before Phases 2-4 begin. Alpha9 returns to the bundle pattern: ship the full TLY-29 / TLY-30 / TLY-31 Phase B set together when complete.

## Alpha9 scope: complete the authoritative-ledger bundle (Phases 2-4)

Picks up where alpha8 left off. Bundle ships:

1. **[TLY-29](https://github.com/gezmodean-wow/tally/issues/29)** — Capture-layer rigor: `Ledger.Schema`, `Ledger.Kinds.Unknown` + kind router, structured per-source field map
2. **[TLY-30](https://github.com/gezmodean-wow/tally/issues/30)** — `Ledger.Authority` priority map, `Ledger:Reconcile(filter)` API, consumer migrations (Lifecycle, Research, Ledger page)
3. **[TLY-31 Phase B](https://github.com/gezmodean-wow/tally/issues/31)** — Demote sibling adapters to backfill-only by default; periodic ticker off by default; setup wizard wording shifts

Estimated remaining scope: 1200–2000 LOC across schema definition, Reconcile API, consumer migrations, wizard config (Phase 1's adapter resolution + Compare matcher work is done, freeing the "smaller slice" estimate from the previous handoff).

## Phase 2: capture-layer rigor (TLY-29)

Touches every adapter. Phase 1's itemID resolution stabilizes input quality first; this layer formalizes the kind/field router on top.

**`Ledger.lua` additions:**
- `Ledger.Schema = { sale = { canonical = {...}, sourceFields = { tsm = {...}, native = {...}, ... } }, ... }`. Per (kind, source), declare canonical fields + source-specific extras.
- `Ledger.Kinds.Unknown = "unknown"`. `KindSign("unknown")` returns 0 (neutral). Adapters route any source-kind they don't recognize to `Unknown` with the original payload preserved in `meta.sourceKind`.

**Adapter refactor (touches all of them — Native/*, FlipQueue, TSM, Journalator):**
- Each adapter declares which source-kinds it knows. Unknown source-kinds → `Ledger.Kinds.Unknown` instead of silent drop / wrong-kind fallback (TSM currently falls back to `sale` which is wrong if the source was actually "Trade").
- Migrate the free-form `meta` table population to declare canonical vs source-specific fields per the new Schema. Existing `meta` consumers in Lifecycle / Research keep working — Schema is additive structure, not a replacement.
- Keep skip counters (already in place from earlier work + Phase 1 additions); they're the loss-accounting half of TLY-29.

## Phase 3: authoritative ledger via Reconcile (TLY-30)

The big workstream. Probably one full session minimum.

**`Ledger.lua` additions:**
- `Ledger.Authority = { sale = { atTime = { "native", "journalator", "tsm" }, copper = { "tsm", "native", "journalator" }, ... }, ... }`. Per (kind, field), declare source priority.
- `Ledger:Reconcile(filter) -> records[]` — groups raw query results by `(charKey, itemID, count_window, atTime_window)` (same heuristic Compare uses). For each grouped event, build one record where each field comes from the highest-priority source that has it, with `provenance = { atTime = "native", copper = "tsm", ... }` mapping field → source.

**Consumer migrations:**
- `Research/Lifecycle.lua`: switch sale-matching from `Ledger:Query` to `Ledger:Reconcile`. Users with Journalator no longer see duplicate cohorts when Native + Journalator both observed the same posting.
- `Research/Aggregator.lua`: `Research:GetRecord` switches sales/purchases from raw `Query` to `Reconcile` so per-item P&L stops over-counting.
- `UI/LedgerPage.lua`: add a `Reconciled / Raw` toggle. Default to Reconciled. Raw mode preserved for power-user debugging.
- `NetWorth/Calculator.lua`: no change — reads Inventory + Pricing, not the ledger.

## Phase 4: demote sibling adapters (TLY-31 Phase B)

Smaller; can land same session as Phase 3 if time permits.

- Sibling-adapter periodic ticker default flips: `TallyDB.sourcePolicy.tickerEnabled = false` (was effectively-true via 5-min `C_Timer.NewTicker` in `Core.lua` PLAYER_LOGIN). Native source stays event-driven (no change).
- One-shot at PLAYER_LOGIN still fires for sibling adapters (so backfill works without user action), but no recurring tick.
- `UI/SetupWizard.lua` source-detection step wording: relabel sibling sources as "Backfill from <source>" rather than "Import from <source>". Helps users understand the new role.
- `UI/SettingsPage.lua` DATA SOURCES section: add a label clarifying that sibling-source imports are now manual / one-shot, with "Import now" buttons per source unchanged.

## Tester signals still live (independent of alpha9 bundle)

- **[TLY-17](https://github.com/gezmodean-wow/tally/issues/17)** — surface "currently posted on AH" sub-line in net worth view. Data is already tracked (auctions location); just needs the UI surface.
- **[TLY-18](https://github.com/gezmodean-wow/tally/issues/18)** — multi-archive ledger storage + offline export/restore tooling. Long-running.
- **[TLY-20](https://github.com/gezmodean-wow/tally/issues/20)** — Curseforge install issue from alpha1. Retest comment posted; awaiting tester response on alpha7.
- **[TLY-24](https://github.com/gezmodean-wow/tally/issues/24)** — Toeknee's TSM-vs-Tally discrepancy umbrella. Phase 1 (TLY-36) addresses the itemID-resolution slice; full close needs Phases 2-3.
- **[TLY-28](https://github.com/gezmodean-wow/tally/issues/28)** — Inventory tab empty. Awaiting tester diag.
- **[TLY-32](https://github.com/gezmodean-wow/tally/issues/32)** — Lua warning across alpha4-6. Retest comment posted; awaiting tester response on alpha7.
- **[TLY-33](https://github.com/gezmodean-wow/tally/issues/33)** — Closed but waiting for tester re-test confirmation that the alpha6 fix resolved the integer overflow.
- **[TLY-35](https://github.com/gezmodean-wow/tally/issues/35)** — Welcome popup per-toon question (filed by scribe; not yet triaged).
- **[TLY-39](https://github.com/gezmodean-wow/tally/issues/39)** — Cogworks v0.13.1 bump shipped in alpha7. Pending tester verification of game-menu / logout / quit dialogs working post-Tally-window-open.
- **TLY-40 / 41 / 42 / 43 / 44** — alpha8 fixes; pending in-game verification. Close after the user confirms.

If any of these get tester replies during the alpha9 work cycle, evaluate whether to fold into alpha9 or split as alpha9-hotfix tags. Per cadence preference, prefer folding when feasible.

## Waiting on Cogworks

- **[cogworks#23](https://github.com/gezmodean-wow/cogworks/issues/23)** — `CreateProgressBar` primitive. `UI/ProgressBar.lua` + `UI/MultiProgressBar.lua` are Tally-local pending this; lift when it lands.
- **[cogworks#27](https://github.com/gezmodean-wow/cogworks/issues/27)** — verify-package reusable workflow. Already landed and wired into Tally's release.yml; close on cogworks side once Gezmo confirms.
- **[cogworks#29](https://github.com/gezmodean-wow/cogworks/issues/29)** — verify-package script needs to normalize backslash → forward-slash in TOC paths before file existence checks. Tally worked around by switching its own TOC to forward slashes; other cogs in the suite may still trip the bug until cogworks fixes it. Also revisit the ThemedMainFrame.SetSummary anchor issue (filed loosely under TLY-42's commit comment but not yet a cogworks-side ticket — the primitive needs an "only when sidebar shown" mode for consumers using tab-strip layouts).

## Handy facts

- Last acknowledged scribe player-facing conventions: `2026-04-30f` (re-fetch when next writing player-facing copy)
- Cogworks pinned at `v0.13.1` in `.pkgmeta`
- Origin current as of `0917052` (alpha8 TOC fix commit, where the tag now points)
- Slash commands now use `cw:RegisterSlashCommands` — auto-help renders from per-command `{ name, run, help, args, aliases }`. Add new commands as table entries in `Core.lua`'s `RegisterSlashCommands` block, not via separate `SLASH_*` globals.
- Debug toolkit: `ns.dbg:PrintDebug(...)` for trace logging; `/tally debug` toggles the live console; `/tally diag copy` opens the structured paste-friendly dump.
- Memory entries to read when starting: `feedback_alpha_cadence` (the cadence rule), `feedback_no_push_without_approval` (push approval), `feedback_ui_before_ship` (UI-before-shipping principle), `project_scope` (what Tally is), `feedback_player_summary` (scribe doc URL).
