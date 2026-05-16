# Tally — next session handoff

alpha19 shipped 2026-05-14. Nothing is in flight — `main` is clean and synced with `origin`. The next session is greenfield: pick up either the TLY-73 tab-structure rework (the next planned major piece) or whatever tester feedback lands on alpha19 first.

## State

- **Branch:** `main`, synced with `origin/main`. Working tree clean.
- **Latest commit:** `95d1099` — `fix: Lifecycle:Analyze returns (analysis, cohorts) even on zero-row items`.
- **Latest tag:** `v0.1.0-alpha19` (at `95d1099`), shipped 2026-05-14 → CurseForge + Wago via the BigWigsMods packager. Release page: https://github.com/gezmodean-wow/tally/releases/tag/v0.1.0-alpha19
- **Cogworks pinned at `v0.14.1`** in `.pkgmeta`. Verified in the alpha19 release build log — the packager fetched `v0.14.1` and vendored it into the shipped zip, so players get the debug-console tab-overlap fix.
- **Standards acknowledgments** (per `CLAUDE.md`): runbooks at `2026-05-05a`, scribe player-facing at `2026-04-30f`. Both verified current 2026-05-13.

## What alpha19 shipped

Four themes, ~14 commits, one tag. Full engineering detail in `CHANGELOG.md` `## [v0.1.0-alpha19]` once promoted from `## [Unreleased]` (see "Loose end" below).

- **TLY-71 Flow A — manual import controller.** Setup wizard Steps 4+5 (source picker + window + pace presets), `Util/Import.lua` chunked-backfill state machine (pause/resume/cancel, logout-survivable via `TallyDB.import.pending`), `/tally import` slash, `UI/ImportControl.lua` persistent draggable control widget.
- **TLY-71 Flow B — on-demand period synthesis.** `Util/Synthesis.lua` engine (parses siblings once, buckets by month, writes one archive per period), `Archive.lua` LRU slot eviction + freed-slot recycling, `/tally synth` slash, `UI/SynthButton.lua` "Synthesise history" button on Research / Lifecycle / Compare.
- **TLY-69 — multi-source gold authority.** Per-character gold picks the freshest of Tally-native capture / Syndicator snapshot / TSM goldLog. `/tally diag gold` shows per-source columns + chosen-source provenance.
- **TLY-70 — output-channel taxonomy.** Every player-visible string routes through `ns.Output` (toast / copy-dialog / debug-console / mirrored-chat).
- Plus the `ae00460` warband-row UI split (gold vs items) and the `95d1099` Lifecycle zero-row crash fix found during the post-ship smoke test.

## Post-ship done

- Player-update comments posted on TLY-24, TLY-68, TLY-69, TLY-71 — scribe mirrors them to the Discord forum threads.
- Cogworks pin confirmed correct (v0.14.1) in the shipped artifact.
- `/tally debug` confirmed working in-game on v0.14.1.

## Loose end to clear early next session

- **`CHANGELOG.md` + `RELEASES.md` still have the alpha19 content under `## [Unreleased]` / `## Unreleased`.** The release flow convention (see other cogs) is to promote the heading to the tagged version after the tag lands. Rename `## [Unreleased]` → `## [v0.1.0-alpha19]` in `CHANGELOG.md` and `## Unreleased` → `## v0.1.0-alpha19` in `RELEASES.md`, then re-add empty `## [Unreleased]` / `## Unreleased` stubs at the top. (alpha17's `647858c` "promote Unreleased" commit is the pattern.) Low-priority but do it before the next changelog entry so the next alpha's notes don't pile onto alpha19's.

## Not yet smoke-tested live

These shipped but weren't exercised in-game before the tag — verify when convenient, or wait for tester reports:

- **Import wizard Steps 4+5 + control widget.** Needs a setup-wizard run, which only auto-shows when setup isn't complete (`/tally reset` triggers it but wipes the ledger — alpha-tester data is expendable per the project memory, so this is acceptable if you want to test). The widget itself: drag, minimise-to-badge, budget/delay edit, pause/resume/cancel.
- **A real synthesis run.** The Synthesise button tooltip + confirm popup were the only parts touched. An actual `EnsurePeriods` run against a big TSM CSV (the 2-3s first-parse block, per-period toasts, LRU eviction when the 60-slot pool fills) is unverified.

## Next major piece — TLY-73

**[TLY-73](https://github.com/gezmodean-wow/tally/issues/73)** — tab-structure rework, filed 2026-05-13 from the alpha19 smoke-test reframe. Two parts:

1. **Fold Lifecycle into Research as a per-item drill-down.** Today Lifecycle is a peer tab; the "View lifecycle →" button at `UI/ResearchPage.lua:123` jumps to it. Intended: Lifecycle becomes an in-page expander/sub-view under Research, collapsing one top-level tab.
2. **Global History time-window navigator.** A cross-cutting date-range selector that every page scopes its data against — closest current analogue is Compare's binary "Include archives (slow)" toggle. Wants a `ns.History.activeWindow`-style state pages subscribe to; the Synthesise button becomes period-scoped ("fill the periods this window covers") rather than "fill everything missing."

TLY-73 needs a design pass before implementation — the History navigator is a real architecture decision (how pages subscribe, how the active window interacts with the active-only working set vs lazy archive loads). Start there with a Plan, not code.

## alpha20 candidate work

Per the alpha cadence, alpha20 = tester-reported alpha19 fixes + planned work. Planned candidates:

- **TLY-73** (above) — the anchor if no urgent tester fixes land.
- **Adopt `cw:CreateMultiTaskProgress`** in `UI/ImportControl.lua`. Cogworks v0.14.0 shipped this primitive with Tally's import controller named as its v1 driver. The refactor: drop ~250 LOC of per-row rendering + frame chrome onto the primitive, keep the listener wiring + budget/delay inputs + minimise badge. Optionally `cw:CreateTaskProgress` (single-bar) for the synthesis surface.
- **[TLY-72](https://github.com/gezmodean-wow/tally/issues/72)** — adopt `cw:CreateAppearanceTab` as the Settings Appearance tab (mirrors cogworks#71). Self-contained, small.
- **Adopt `cw:ShowItemKeyTooltip`** — collapses ~6 near-identical tooltip-setup blocks across the UI pages. Cleanup, no behavior change.
- **`RegisterDebugAction` pass** — now that `/tally debug` opens, register Tally debug actions via v0.14.0's opts-table form (groups, help tooltips). The Actions tab is currently empty by design.
- **[TLY-65](https://github.com/gezmodean-wow/tally/issues/65)** — zpectre divergence freeze. Independent of the rewrite; deferred from alpha19.
- **[TLY-67](https://github.com/gezmodean-wow/tally/issues/67)** is CLOSED (minimap placement); don't re-pick it.

## Open issues (status)

- **[TLY-71](https://github.com/gezmodean-wow/tally/issues/71)** — import controller + synthesis. Shipped in alpha19. Close after testers run the import flow and data converges.
- **[TLY-69](https://github.com/gezmodean-wow/tally/issues/69)** — multi-source gold authority. Shipped. Close after Toeknee's `/tally diag gold` confirms freshest-source picks.
- **[TLY-70](https://github.com/gezmodean-wow/tally/issues/70)** — output-channel consolidation. Shipped; close with alpha19 confirmation.
- **[TLY-68](https://github.com/gezmodean-wow/tally/issues/68)** — gold accounting. alpha19's TLY-69 + warband split close the user-visible paths; close pending tester confirmation.
- **[TLY-24](https://github.com/gezmodean-wow/tally/issues/24)** — TSM-vs-Tally ledger comparison. Stays open until Toeknee re-runs Compare with the alpha19 import filled.
- **[TLY-73](https://github.com/gezmodean-wow/tally/issues/73)** — tab rework. New, design-pending.
- **[TLY-66](https://github.com/gezmodean-wow/tally/issues/66)** — CSV-shaped slots (~20× archive memory drop). alpha20+ when synthesis filling the slot pool makes archive memory growth user-visible.
- **[TLY-65](https://github.com/gezmodean-wow/tally/issues/65)** — zpectre divergence freeze. Independent; alpha20 candidate.

## Live testers

- **Toeknee_atx** — primary big-roster tester (68 chars). alpha19's import flow restores the sibling-source data alpha18's wipe removed; TLY-69 should close his 63M toon-gold gap. Player updates posted on TLY-24/68/69/71 — watch those threads for his alpha19 response.
- **zong** — 53-char roster, was on alpha17 last we heard. Same gold-staleness pattern at smaller scale.
- **_zpectre_** — last known on alpha15 (438k rows). Hasn't posted on alpha16-19. Worth a check-in; TLY-65 is his.

## Cross-cog (waiting on Cogworks)

- **[cogworks#23](https://github.com/gezmodean-wow/cogworks/issues/23)** — `CreateProgressBar` primitive. Likely satisfied by v0.14.0's `CreateTaskProgress` / `CreateMultiTaskProgress` (shipped under the "TaskProgress" name to avoid colliding with the existing inline-cell `CreateProgressBar`). Close it if not already done.
- **[cogworks#27](https://github.com/gezmodean-wow/cogworks/issues/27)** / **[#29](https://github.com/gezmodean-wow/cogworks/issues/29)** — verify-package workflow + TOC-slash normalisation.
- **[cogworks#34](https://github.com/gezmodean-wow/cogworks/issues/34)** — `sync-standards.sh check` parsing bug.
- **[cogworks#35](https://github.com/gezmodean-wow/cogworks/issues/35)** — `.gitattributes` for `*.sh eol=lf`.
- **[cogworks#56](https://github.com/gezmodean-wow/cogworks/issues/56)** — debug-console crash. CLOSED; fix shipped in v0.14.0, tab-overlap follow-up in v0.14.1. Resolved for Tally.

## Handy facts

- alpha19 at `95d1099`, tagged `v0.1.0-alpha19`. `main` synced with `origin`.
- Cogworks pinned `v0.14.1` in `.pkgmeta`. v0.14.x added eight primitives (Stepper, Drawer animate, ShowLoading, MiniView persistKeys, Debug per-cog action registry, ShowItemKeyTooltip, Wizard per-step footer, TaskProgress).
- New modules from alpha19: `Util/Import.lua` (import driver), `Util/Synthesis.lua` (archive-fill engine), `UI/ImportControl.lua` (import widget), `UI/SynthButton.lua` (Synthesise-history button). `Util/Output.lua` is the channel router.
- `Archive.lua` now runs LRU slot eviction — `archiveIndex[key].lastAccessedAt` stamped on Save+Load; `TallyDB.ledger.freedSlots` recycles explicit deletes.
- TSM goldLog storage shape: `s@<char> - <faction> - <realm>@internalData@goldLog`, value = `"minute,copper\n..."` (balance snapshots).
- Memory entries to read when starting: `project_architecture_rewrite_plan` (alpha19 closed its scope — the rewrite is done), `project_pro_service_direction`, `feedback_alpha_cadence`, `feedback_no_push_without_approval`, `feedback_ui_before_ship`, `feedback_player_summary`, `feedback_output_channels`, `feedback_enhancements_to_issues`.
