# Tally — next session handoff

alpha19 is ship-ready. The critical-path work landed across the 2026-05-12 → 2026-05-13 sessions; CHANGELOG + RELEASES are written; the Cogworks pin is bumped to `v0.14.0` (which carries the cogworks#56 fix that was blocking `/tally debug`). Open the next session by deciding whether to tag `v0.1.0-alpha19` immediately or run one more local smoke test.

## State

- **Branch:** `main`, 7 commits ahead of `origin/main` (unpushed by design — push gated on per-tag approval).
- **Latest commit:** `<head>` — `chore: bump Cogworks pin to v0.14.0 + refresh NEXT_SESSION` (this session).
- **Latest tag:** `v0.1.0-alpha18` shipped 2026-05-09. `v0.1.0-alpha19` is the next tag, awaiting approval.
- **Cogworks pinned at `v0.14.0`** in `.pkgmeta` (bumped from `v0.13.2`). Picks up the cogworks#56 fix + eight new primitives from the FlipQueue v0.13 adoption audit, including `lib:CreateTaskProgress` / `CreateMultiTaskProgress` (release notes literally name Tally's import controller + synthesis flow as the v1 drivers).
- **Standards acknowledgments** (per `CLAUDE.md`): runbooks at `2026-05-05a`, scribe player-facing at `2026-04-30f`. Both current as of 2026-05-13.

## What alpha19 ships

Seven thematic commits stack on top of `1d4235d` (the TLY-69 baseline pushed end of last session). All on `main`, unpushed.

- **`8fe5557` — TLY-71 setup wizard Steps 4+5.** Two new wizard steps that register conditionally when sibling adapters are loaded — fresh installs with no siblings keep alpha18's 3-step flow. Step 4 surfaces per-source checkboxes + 30d/90d/12mo/all window selector; reads `:ProbeMetadata()` into `state.probes` on first entry. Step 5 surfaces budget + delay numeric inputs with gentle/balanced/aggressive pace presets and a live "Estimate: ~3m 20s for 47,213 rows across 2 sources" line.
- **`45698fd` — TLY-71 import driver state machine + slash.** `Util/Import.lua` is the chunked-backfill controller — `idle → configured → running ⇄ paused → flushing → done`. Survives logouts via `TallyDB.import.pending` (entries[] excluded; re-parsed from sibling SV on Resume with idx seek). PLAYER_LOGIN's 7s deferred restore wakes the controller in paused state — TLY-71 chose explicit Resume over auto-resume. `/tally import` subcommands: `status` (copy-dialog), `pause`, `resume`, `cancel`, `budget <rows>`, `delay <sec>`.
- **`f8f3b63` — TLY-71 import control widget.** `UI/ImportControl.lua` — singleton draggable always-on-top panel listener-wired to `ns.Import`. Per-source rows with state-coloured progress bars + cadence-derived ETA. Editable budget/delay inputs (commit on Enter or focus-lost). Pause/Resume/Cancel buttons. `[_]` minimises to a 28px badge near the minimap (own persisted position); `[X]` is the same as Cancel — `StaticPopup` confirm that preserves pending state. Position persists at `TallyDB.ui.importController` with separate expanded/minimised positions and a mode flag. Auto-fades 6s after `done`. Show entry points: wizard `onComplete`, PLAYER_LOGIN restore, bare `/tally import`, `/tally import resume`.
- **`ffe2a38` — TLY-71 period synthesis engine + Archive LRU.** `Util/Synthesis.lua` is the on-demand archive-fill engine — same state-machine shape as `ns.Import` so a future shared widget could subscribe to both. `EnsurePeriods(keys, opts)` parses each enabled source once (cached), bucket-sorts entries by `date("%Y-%m", atTime)`, writes one archive per period. `GetCandidates({})` partitions candidate months into missing / already-archived / current-month (skipped — that's the active set's job). Archive.lua now stamps `lastAccessedAt` on Save+Load and runs LRU eviction when `nextSlot ≥ SLOT_COUNT`; freed slots (from explicit `Delete()`) are pushed onto `TallyDB.ledger.freedSlots` and reused before any eviction. The 60-slot pool runs in steady-state recycle mode indefinitely. `/tally synth` subcommands: `start` (default), `status` (copy-dialog + idle-state coverage probe), `pause`, `resume`, `cancel`.
- **`d16dda8` — TLY-71 Synthesise history button on three pages.** `UI/SynthButton.lua` exports `ns.UI.CreateSynthButton(parent)`. Tooltip with live coverage probe (uses `ProbeMetadata.byMonth` so it stays cheap — no full sibling parse). Click → `StaticPopup` confirm → `Synthesis:EnsurePeriods`. Listens to the singleton job; disables + relabels across all pages to "Synthesising…" / "Synth paused" / "Flushing…". Anchored: Research (right of "View lifecycle →"), Lifecycle (right of FIFO/Avg toggle), Compare (right edge of toggle row, deliberately paired with "Include archives (slow)").
- **`6051e61` — alpha19 changelog + release notes.** Engineering `## [Unreleased]` in `CHANGELOG.md` covers the four themes (TLY-69 gold authority, TLY-70 channel taxonomy, TLY-71 Flow A import controller, TLY-71 Flow B synthesis) with file:line refs + TLY-N IDs. Player-facing `## Unreleased` in `RELEASES.md` leads with "what's restored vs alpha18's deferral" and co-mentions the chat-output consolidation + warband row split.
- **`<head>` — Cogworks pin v0.13.2 → v0.14.0 + this NEXT_SESSION refresh.** Picks up the cogworks#56 fix + the new debug-console / task-progress / loading / stepper primitives. No code change inside Tally yet; the primitives are queued for adoption (see "Migration opportunities" below).

Pre-session TLY-69 + TLY-70 + warband-row-split commits (`1d4235d`, the TLY-70 cohort series, `ae00460`) round out the alpha19 bundle. Total alpha19 commit count: 12 thematic + 1 changelog + 1 pin-bump.

## Ship steps (when you're ready)

1. **Smoke-test in-game.** Reload after pulling. Verify: the welcome wizard's new Steps 4/5 render when a sibling is loaded, the import widget appears + accepts budget/delay edits, `/tally import status` opens the widget when a controller exists, `/tally synth status` shows the coverage probe when idle, the Synthesise button tooltip lists candidate months.
2. **Verify `/tally debug` opens** without the cogworks#56 crash now that v0.14.0 is pinned. If it does, this is the first build where the live debug console is actually usable.
3. **Push `main`.** `git push origin main` — six unpushed commits land.
4. **Tag.** `git tag v0.1.0-alpha19` then `git push origin v0.1.0-alpha19`. The BigWigsMods packager picks up the tag, builds against the Cogworks v0.14.0 external, and uploads to CurseForge + Wago with `RELEASES.md`'s `## Unreleased` as the per-release changelog.
5. **Post the release note** to the Discord testers (Toeknee_atx, _zpectre_, Zong). The two big things they'll care about: the manual import flow restoring sibling-source data they lost on alpha18's wipe, and the per-character gold accounting picking the freshest source (closes Toeknee's 63M toon-gold gap).

## Migration opportunities (alpha20+)

Cogworks v0.14.0's release notes call out two primitives whose v1 driver is explicitly Tally's alpha19 work:

- **`cw:CreateMultiTaskProgress`** (`Cogworks-1.0/TaskProgress.lua`) — dockable multi-row progress widget with per-source rows, state colours (`queued | importing | done | error | skipped`), `:Pulse()` indeterminate animation, `:SetETA()`, persisted position, and a 1.5s linger + 0.6s fade on `:Complete()`. Tally's `UI/ImportControl.lua` (custom-built this session) was the *prior art* the primitive distilled; the alpha20 refactor is "rip out our per-row rendering and chrome, keep our listener wiring + budget/delay inputs + minimise badge." Net reduction: ~250 LOC.
- **`cw:CreateTaskProgress`** (single-bar variant) — fits the per-period synthesis surface; alternative to the current toast-only progress for synthesis. Optional alpha20 adoption.

Other v0.14.0 primitives worth knowing about (Tally consumers, not current refactor candidates):

- **`cw:ShowLoading(parent, opts)`** — async-state overlay with indeterminate dot-wave + determinate brass status bar. Could replace the "synthesising…" toast cadence if we want a more focused in-page state.
- **`cw:CreateStepper`** — queue-based one-at-a-time walkthrough, Wizard's sibling for unknown-length flows. Not currently needed but worth knowing about for any future "process N items" flows.
- **`CreateDrawer` edge-reveal animation** — additive `opts.animate` on the existing primitive.
- **`CreateMiniView` `opts.persistKeys`** — whitelist of geometry keys to persist. Useful when we want pinned/collapsed state to reset per-login.
- **`RegisterDebugAction` opts table + per-cog action registry** — groups, help tooltips, disabled state, lazy-rebuild. Worth a pass over Tally's debug actions once `/tally debug` actually opens.
- **`cw:ShowItemKeyTooltip`** — collapses six near-identical tooltip-setup blocks across Tally's pages into one call. Cleanup-only, no behavior change.
- **`CreateWizard` per-step custom footer** — wizard step can supply its own footer. Useful for future setup-wizard variants.

## Open issues / backlog status

- **[TLY-71](https://github.com/gezmodean-wow/tally/issues/71)** — manual import + period synthesis. Both flows implemented + shipping in alpha19. Stays open until testers validate; close after Toeknee + zong run the new import flow against their rosters and the data converges.
- **[TLY-69](https://github.com/gezmodean-wow/tally/issues/69)** — multi-source gold authority. Shipped in `1d4235d`. Closes when alpha19 lands and the diag confirms freshest-source picks on Toeknee's roster.
- **[TLY-70](https://github.com/gezmodean-wow/tally/issues/70)** — output-channel consolidation. Six cohorts shipped; closes with alpha19.
- **[TLY-68](https://github.com/gezmodean-wow/tally/issues/68)** — gold accounting investigation. Foundation in alpha18; alpha19's TLY-69 + warband-row split close the user-visible paths.
- **[TLY-24](https://github.com/gezmodean-wow/tally/issues/24)** — TSM-vs-Tally ledger comparison. Gold conversation closes with TLY-69; ledger comparison stays open until Toeknee re-runs Compare with the alpha19 import filled.
- **[TLY-65](https://github.com/gezmodean-wow/tally/issues/65)** — zpectre divergence freeze. Independent of the rewrite; not in alpha19 scope. Carry to alpha20.
- **[TLY-67](https://github.com/gezmodean-wow/tally/issues/67)** — minimap forgets placement. Small bug, alpha20+.
- **[TLY-66](https://github.com/gezmodean-wow/tally/issues/66)** — CSV-shaped slots (lazy-parsed strings, ~20× memory drop). alpha20+ when archive memory growth becomes user-visible (synthesis can fill all 60 slots fast).
- **[cogworks#56](https://github.com/gezmodean-wow/cogworks/issues/56)** — debug-console crash. **Closed** on the Cogworks side, fix shipped in v0.14.0. Once Tally's alpha19 builds against v0.14.0, `/tally debug` should open cleanly for the first time.

## Backlog (post-alpha19)

- **Adopt `cw:CreateMultiTaskProgress`** in `UI/ImportControl.lua` (alpha20 refactor — drop ~250 LOC of per-row rendering + frame chrome).
- **Adopt `cw:ShowItemKeyTooltip`** across the UI pages (cleanup; six near-identical blocks).
- **Character-key realm-normalisation** — adopt Cogworks `Realms.lua`. Lead from TLY-32 dig.
- **LedgerPage bundle (TLY-52 + TLY-53 + TLY-56)** — item icon + quality-color name, right-click context menu, filter chip overlap fix.
- **[TLY-54](https://github.com/gezmodean-wow/tally/issues/54)** — item-finder sidebar. Bigger refactor, needs design pass on the All-WoW scope.
- **[TLY-61](https://github.com/gezmodean-wow/tally/issues/61)** — Native AHCancel coverage hole.
- **Refactor `/tally diag` onto `cw:CreateDebug`** now that v0.14.0 unblocks the console. Add `dbg:Print` traces along the way per the alpha18 memory.
- **Optional post-wipe chat softener** for upgraders who hit the alpha18 first-load overflow error. Not urgent.

## Cross-cog (waiting on Cogworks)

- **[cogworks#23](https://github.com/gezmodean-wow/cogworks/issues/23)** — `CreateProgressBar` primitive. Note: v0.14.0 shipped `CreateTaskProgress` + `CreateMultiTaskProgress` under the "TaskProgress" naming (deliberately distinct from the existing inline-cell `CreateProgressBar` primitive). cogworks#23's original ask was the dockable variant; v0.14.0 satisfies it under the new name. Close cogworks#23 if not already done.
- **[cogworks#27](https://github.com/gezmodean-wow/cogworks/issues/27)** — verify-package reusable workflow.
- **[cogworks#29](https://github.com/gezmodean-wow/cogworks/issues/29)** — verify-package backslash → forward-slash TOC normalisation.
- **[cogworks#34](https://github.com/gezmodean-wow/cogworks/issues/34)** — `sync-standards.sh check` parsing bug.
- **[cogworks#35](https://github.com/gezmodean-wow/cogworks/issues/35)** — `.gitattributes` for `*.sh eol=lf`.

## Handy facts

- alpha19 commits sit on top of alpha18 (`v0.1.0-alpha18` tag at 2026-05-09). Six unpushed commits + one pin-bump on `main`.
- Cogworks pinned at `v0.14.0` in `.pkgmeta`. v0.14.0 bumped lib MINOR 19 → 26; eight primitives added (Stepper, Drawer animate, ShowLoading, MiniView persistKeys, Debug per-cog action registry, ShowItemKeyTooltip, Wizard per-step footer, TaskProgress).
- `TallyActive` declared in `tally.toc` alongside `TallyA001..TallyA060`. `Util/Output.lua` is the channel router for all user-visible output. `Util/Import.lua` is the chunked import driver. `Util/Synthesis.lua` is the on-demand archive-fill engine. `UI/ImportControl.lua` is the persistent import widget. `UI/SynthButton.lua` is the reusable Synthesise-history button.
- Last acknowledged scribe player-facing conventions: `2026-04-30f` (verified 2026-05-13 — no newer entries).
- All cogworks runbooks acknowledged at `2026-05-05a`. Cogworks v0.14.0 release didn't touch the runbooks; no re-ack needed.
- TSM goldLog storage shape verified in live SV: `s@<char> - <faction> - <realm>@internalData@goldLog`, value = `"minute,copper\n<minute>,<copper>\n..."` (balance snapshots, not deltas).
- Memory entries to read when starting: `project_architecture_rewrite_plan` (alpha19 closes its scope), `project_pro_service_direction`, `feedback_alpha_cadence`, `feedback_no_push_without_approval`, `feedback_ui_before_ship`, `feedback_player_summary`, `feedback_output_channels`.
