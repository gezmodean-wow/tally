# Tally — next session handoff

Picks up after the 2026-05-04 alpha10 work session. Bundle is committed + locally tagged on `feat/authoritative-ledger`; awaiting user push approval.

## State

- **Branch:** `feat/authoritative-ledger`, 11 commits ahead of `main`. Local tag `v0.1.0-alpha10` on the head commit. **Nothing pushed.**
- **Bundle composition** (commits, oldest first):
  - `4358b22` — `fix(TLY-35)`: welcome popup respects skip + LDB calm tone for skipped state. (Originally landed on `main` as the alpha9 popup-fix slice; folded into the alpha10 bundle per user direction once testers logged off for the night.)
  - `640effe` — `feat(TLY-29)`: Ledger schema + Unknown kind + BuildUnknownEntry helper.
  - `ff31efa` — `fix(TLY-29)`: TSM adapter routes unknown source-kinds to Unknown bucket.
  - `2cdc7ad` — `fix(TLY-29)`: FlipQueue adapter routes unknown auctionStatus to Unknown.
  - `0ce955c` — `fix(TLY-29)`: Journalator adapter routes unknown bucket discriminators to Unknown.
  - `cadb1db` — `fix(TLY-29)`: Native AHInvoice routes unknown invoiceType to Unknown bucket.
  - `894174a` — `feat(TLY-30)`: Ledger.Authority + Ledger:Reconcile with per-field provenance.
  - `18138f2` — `feat(TLY-30)`: Lifecycle + Aggregator migrate from Query to Reconcile.
  - `821c6fb` — `feat(TLY-30)`: LedgerPage Reconciled/Raw mode toggle.
  - `446f861` — `feat(TLY-29)`: Unknown filter chip on LedgerPage.
  - `e3bd325` — `feat(TLY-31,TLY-45)`: Phase 4 — sibling backfill stance + divergence diagnostic.
  - `9886d1d` — `docs`: promote Unreleased → v0.1.0-alpha10 in CHANGELOG + RELEASES.
- **Working tree clean.** `git diff main..HEAD --stat` shows ~1500 LOC across `Ledger.lua`, four source adapters, two Research consumers, four UI files, both changelogs, Core.lua.
- Cogworks pinned at `v0.13.1` in `.pkgmeta`; vendored `Libs/Cogworks-1.0/` synced (gitignored).
- Memory at `C:\Users\gezmo\.claude\projects\C--src-tally\memory\` is current.

## To ship alpha10

User has authorized the bundle work but not the push (per `feedback_no_push_without_approval`). Steps remaining:

1. **Merge `feat/authoritative-ledger` → `main`.** Fast-forward eligible — `main` is an ancestor of feat. `git checkout main && git merge --ff-only feat/authoritative-ledger`. (Alternatively, `git push origin feat/authoritative-ledger:main` if the user prefers updating remote main directly without local checkout.)
2. **Push `main`.** `git push origin main`.
3. **Push the tag.** `git push origin v0.1.0-alpha10`. Triggers `release.yml` → BigWigsMods packager → CurseForge + Wago.
4. **Watch the CI run.** Verify the verify-package gate (cogworks#27 reusable workflow) passes; it caught alpha8's TOC backslash issue, so it's a meaningful trigger.

If anything breaks during release (verify gate, packager, channel uploads), the failure mode is similar to alpha8's TOC fix — investigate, fix on `main`, push, re-tag.

## What ships in alpha10

Full authoritative-ledger bundle. Engineering breakdown lives in `CHANGELOG.md`'s `[v0.1.0-alpha10]` section; player-facing prose in `RELEASES.md`. Quick map:

- **TLY-35** — popup gate respects a new "Don't show again" checkbox; LDB launcher shows a calm gray "setup skipped" tooltip + text instead of the gold "setup required" nag for skipped users.
- **TLY-29** — Schema + Kinds.Unknown + BuildUnknownEntry helper. Four-adapter refactor (TSM, FlipQueue, Journalator, Native AHInvoice) routes unrecognized source-kinds through Unknown with original `meta.sourceKind` preserved. New "Unknown" filter chip on Ledger tab.
- **TLY-30** — Authority priority map + Reconcile API + per-field provenance. Lifecycle and Aggregator migrate to Reconcile (no more duplicated cohorts / over-counted P&L for users with overlapping multi-source captures). LedgerPage gets a Reconciled/Raw mode toggle (default Reconciled, persisted via TallyDB.ui.ledgerMode).
- **TLY-31 Phase B + TLY-45** — Sibling backfill stance: 5-min auto-import ticker removed; replaced with 60s heartbeat + one-shot post-login divergence check. Session-window log (`TallyDB.sessions`) feeds `Ledger:DivergenceReport(filter)`. New `/tally diag divergence` command opens copy-dialog with categorized real-gap / expected-gap / field-disagreement rows. Setup wizard + Settings reframed around "backfill" vs "live capture" semantics.
- **Debug UX** — `/tally diag` default switches from chat dump to copy-dialog; `/tally diag chat` preserves the inline-printing path for users who want it; `/tally diag copy` becomes a no-op alias.

## Known caveats (carry into testing)

- **No in-game runtime validation.** ~1500 LOC of structural change across adapters, ledger primitives, and UI; everything was reviewed but not exercised live. Testers should expect to find at least one rough edge.
- **Reconcile clustering window is a guess.** 5-minute anchor-anchored window for same-event clustering across sources. If testers report legitimate clusters that should have merged but didn't, that's the knob to widen.
- **Aggregator's `record.sales[i].source`** now carries a representative source (the Authority winner for atTime) rather than the exact adapter. Downstream consumers (FlipQueue's ItemResearch handoff?) might assume single-source semantics — flag if anything looks weird in cross-cog views.
- **LedgerPage's Reconciled/Raw chip pair** is untested — possible the two new chips overflow on narrow Tally windows. Layout is hand-rolled (cogworks SegmentedControl isn't wired here yet).
- **Existing ledger rows tagged `kind = "sale"` from old TSM imports may have actually been Trade rows.** Phase 2 fixes the routing going forward, but doesn't migrate stale rows. A user re-importing TSM produces new Unknown rows alongside the stale `sale` rows. `/tally clear-source tsm` followed by re-import gives a clean state.

## Tester signals still live (independent of alpha10)

- **[TLY-32](https://github.com/gezmodean-wow/tally/issues/32)** — Lua warning on alpha8. Diag-text-please comment posted; awaiting paste.
- **[TLY-28](https://github.com/gezmodean-wow/tally/issues/28)** — Inventory tab empty (zpectre). Diag-text-please comment posted; awaiting paste.
- **[TLY-20](https://github.com/gezmodean-wow/tally/issues/20)** — Curseforge install issue from alpha1. Retest comment posted on alpha7; still awaiting tester response.
- **[TLY-17](https://github.com/gezmodean-wow/tally/issues/17)** — surface "currently posted on AH" sub-line in net worth view. Data tracked; needs UI surface.
- **[TLY-18](https://github.com/gezmodean-wow/tally/issues/18)** — multi-archive ledger storage + offline export/restore tooling. Long-running.
- **[TLY-24](https://github.com/gezmodean-wow/tally/issues/24)** — Toeknee's TSM-vs-Tally discrepancy umbrella. Phase 1 (TLY-36) addressed itemID resolution; alpha10's Reconcile + Unknown routing closes more of the gap. Worth checking with him whether discrepancies are gone after alpha10.
- **[TLY-39](https://github.com/gezmodean-wow/tally/issues/39)** — Cogworks v0.13.1 bump shipped in alpha7. Pending tester verification of game-menu / logout / quit dialogs working post-Tally-window-open.
- **TLY-40 / 41 / 42 / 43 / 44** — alpha8 fixes; pending in-game verification. Close after the user confirms.

## Waiting on Cogworks

- **[cogworks#23](https://github.com/gezmodean-wow/cogworks/issues/23)** — `CreateProgressBar` primitive. `UI/ProgressBar.lua` + `UI/MultiProgressBar.lua` are Tally-local pending this; lift when it lands.
- **[cogworks#27](https://github.com/gezmodean-wow/cogworks/issues/27)** — verify-package reusable workflow. Already landed and wired into Tally's release.yml; close on cogworks side once Gezmo confirms.
- **[cogworks#29](https://github.com/gezmodean-wow/cogworks/issues/29)** — verify-package script needs to normalize backslash → forward-slash in TOC paths before file existence checks. Tally worked around by switching its own TOC to forward slashes; other cogs in the suite may still trip the bug until cogworks fixes it.

## Next bundle (post-alpha10)

Tester reports drive the next bundle. Likely candidates if no fresh signals come in:

- **[TLY-17](https://github.com/gezmodean-wow/tally/issues/17)** — currently-posted-on-AH sub-line on Net Worth view.
- **Lift `UI/ProgressBar.lua` + `UI/MultiProgressBar.lua` to cogworks** when [cogworks#23](https://github.com/gezmodean-wow/cogworks/issues/23) lands.
- **Refactor `/tally diag` onto `cw:CreateDebug`** when cogworks v0.13's debug primitive matures (per `reference_cogworks_v013_debug.md`).
- **Authority priority audit from real data** — once the divergence reporter has a few weeks of tester data, the Authority map per-(kind, field) priorities can be tuned based on which sources actually win field disagreements in the wild.

## Handy facts

- Last acknowledged scribe player-facing conventions: `2026-04-30f` (re-fetch when next writing player-facing copy)
- Cogworks pinned at `v0.13.1` in `.pkgmeta`
- Origin's `main` is at `4358b22` (the TLY-35 popup fix); local `main` matches; local `feat/authoritative-ledger` is 11 ahead. Local `v0.1.0-alpha10` tag points at `9886d1d`.
- Slash commands now use `cw:RegisterSlashCommands` — auto-help renders from per-command `{ name, run, help, args, aliases }`. Add new commands as table entries in `Core.lua`'s `RegisterSlashCommands` block, not via separate `SLASH_*` globals.
- Debug toolkit: `ns.dbg:PrintDebug(...)` for trace logging; `/tally debug` toggles the live console; `/tally diag` opens the copy dialog by default; `/tally diag divergence` opens the divergence report; `/tally diag chat` falls back to inline chat output.
- Memory entries to read when starting: `feedback_alpha_cadence` (the cadence rule), `feedback_no_push_without_approval` (push approval), `feedback_ui_before_ship` (UI-before-shipping principle), `project_scope` (what Tally is), `feedback_player_summary` (scribe doc URL).
