# Tally — next session handoff

Picks up after the 2026-05-05 / 06 work session that shipped alphas 13 / 14 / 15 and queued the post-public-release backlog. Tester verification cycles are mid-loop on multiple fronts.

## State

- **Branch:** `main`, working tree clean, in sync with `origin/main` at `959b71a`.
- **HEAD commits since the start of this session:**
  - `959b71a` — `fix(TLY-50)`: drop LibDeflate level 5 → 1 + save-time instrumentation in Storage diag.
  - `d4689db` — `docs:` NEXT_SESSION refreshed for alpha13 (now superseded by this one).
  - `bf297e6` — `docs:` promote Unreleased → v0.1.0-alpha14.
  - `00b8e1f` — `feat(TLY-49)`: compressed blob storage for the ledger.
  - `9739054` — `docs:` promote Unreleased → v0.1.0-alpha13.
  - `5c1e272` — `fix(TLY-32,TLY-35)`: per-char marker survives SV load failure.
  - `f3cf81c` — `fix(TLY-48)`: Reconcile clusters require source uniqueness.
- **Tags pushed to origin:** alpha10, alpha11, alpha12, alpha13, alpha14, alpha15. CI green for all (alpha15 in 35s).
- **Cogworks pinned at `v0.13.2`** in `.pkgmeta`.
- Memory at `C:\Users\gezmo\.claude\projects\C--src-tally\memory\` is current.
- `feat/ledger-compression` branch deleted post-merge.
- New vendored libs (alpha14): `Libs/LibSerialize/LibSerialize.lua` (MIT, v5) and `Libs/LibDeflate/LibDeflate.lua` (zlib, v3). Both upstream-verbatim — don't patch unless syncing to a newer release.

## What shipped this session

Three alphas back-to-back, all driven by Toeknee_atx + _zpectre_ + Zong reports:

- **alpha13** — TLY-32 + TLY-35 per-character popup marker, defensive ordering in onCancel, Vendor.lua %d → %.0f overflow fix, TLY-48 Reconcile source-uniqueness gate. Mitigated TLY-35 popup symptom; closed TLY-48 structurally.
- **alpha14** — TLY-49 compressed blob storage. Addresses the SV constant-table-overflow root cause that drove the popup re-fire and ledger-doesn't-persist symptoms. Lazy-load + dirty-tracking + PLAYER_LOGOUT save hook + one-shot legacy migration + new `/tally diag` Storage section.
- **alpha15** — TLY-50 hotfix: LibDeflate level 5 → 1 (~5-10x faster compression on save) + per-step timing exposed in Storage diag. Triggered by Toeknee reporting logout delay introduced by alpha14.

## Closed this session

- **[TLY-35](https://github.com/gezmodean-wow/tally/issues/35)** — welcome popup re-fire. Toeknee + zpectre + Zong all verified the alpha14 + alpha15 chain works (popup once per never-acknowledged alt, then stays gone). Closed.
- **[TLY-57](https://github.com/gezmodean-wow/tally/issues/57)** — accidental duplicate of TLY-55 I filed before noticing scribe had already mirrored Zong's Discord post. Closed as duplicate.

## Filed this session (queue)

- **[TLY-48](https://github.com/gezmodean-wow/tally/issues/48)** — shipped in alpha13. Verified working in Toeknee's post-alpha13 divergence dump (field-disagreement count 3,481 → 0). Awaiting Toeknee's official close-out comment.
- **[TLY-49](https://github.com/gezmodean-wow/tally/issues/49)** — shipped in alpha14. Awaiting tester confirmation that the recovery cycle works (one logout → WoW overwrites broken file → next session loads clean).
- **[TLY-50](https://github.com/gezmodean-wow/tally/issues/50)** — shipped in alpha15. Awaiting Toeknee's verification that logout perf is back to acceptable (diag should show `compress` time in tens-to-hundreds of ms instead of seconds).
- **[TLY-51](https://github.com/gezmodean-wow/tally/issues/51)** — design-only. Tiered storage: active set (≤25k entries / ≤60d) + immutable monthly archives lazy-loaded on demand. Queued for post-public-release. May get bumped to next alpha if Zong's TLY-55 diag confirms the irreducible `LibSerialize:Serialize` cost is the remaining bottleneck.
- **[TLY-52](https://github.com/gezmodean-wow/tally/issues/52)** — Ledger row item icon + quality-colored name (FlipQueue parity). User UX ask, planned bundle.
- **[TLY-53](https://github.com/gezmodean-wow/tally/issues/53)** — Ledger row right-click context menu (Lifecycle / Research / Compare / Copy link). User UX ask, planned bundle.
- **[TLY-54](https://github.com/gezmodean-wow/tally/issues/54)** — Item-finder sidebar for Lifecycle + Research with three filter scopes (inventory / ledger / all WoW). User UX ask, planned bundle. Open design question on the All-WoW scope feasibility.

## Tester-mirrored from Zong (scribe-created)

- **[TLY-55](https://github.com/gezmodean-wow/tally/issues/55)** — "Logout slowed down by alot." Posted engineering comment asking for `/tally diag` Storage section text. Decision tree: if `compress Yms` is large → investigate why TLY-50 didn't take effect; if `serialise Xms` is large → bump TLY-51 to next alpha; if both small → look elsewhere. Awaiting Zong's diag paste.
- **[TLY-56](https://github.com/gezmodean-wow/tally/issues/56)** — Ledger tab filter chips overlap. Confirmed as the alpha10 known caveat ("Reconciled/Raw chip pair untested — possible the two new chips overflow on narrow Tally windows. Layout is hand-rolled."). Routing note added — bundled with TLY-52 + TLY-53 for the next planned LedgerPage bundle. Workaround is widen the Tally window.

## Next concrete work (in priority order)

1. **Wait for Zong's TLY-55 diag.** Drives whether TLY-51 needs bumping or if a different perf path is at play. Should arrive within a session or two.
2. **Wait for Toeknee's alpha14 / alpha15 verification.** Once confirmed, close TLY-32 + TLY-49 + TLY-50.
3. **LedgerPage bundle (TLY-52 + TLY-53 + TLY-56).** All three touch the same row-rendering territory in `UI/LedgerPage.lua`. Sized as a planned bundle (~1.5-2 days). Ship target: post-public-release alpha if no urgent feedback intervenes, OR sooner if user wants to clear the UX backlog before the public release for first-impression polish.
4. **TLY-54 item-finder sidebar.** Bigger refactor (~1-2 days). Independent of LedgerPage; needs design pass on the All-WoW scope.
5. **TLY-51 tiered storage.** Most substantial refactor on the queue. Stays in the next-alpha-after-public-release slot unless TLY-55 diag forces it earlier.

## Other tester signals still live (independent)

- **[TLY-47](https://github.com/gezmodean-wow/tally/issues/47)** — duplicate of flipqueue#147 (bag UI taint). Separate agent on the FQ fix; closes when FQ ships.
- **[TLY-28](https://github.com/gezmodean-wow/tally/issues/28)** — Inventory tab empty (zpectre). Awaiting paste.
- **[TLY-20](https://github.com/gezmodean-wow/tally/issues/20)** — Curseforge install issue from alpha1. Awaiting tester response.
- **[TLY-17](https://github.com/gezmodean-wow/tally/issues/17)** — surface "currently posted on AH" sub-line in net worth view.
- **[TLY-18](https://github.com/gezmodean-wow/tally/issues/18)** — multi-archive ledger storage + offline export/restore. Long-running.
- **TLY-39 / 40 / 41 / 42 / 43 / 44** — alpha7/8 fixes; pending in-game verification. Close after user confirms.

## Waiting on Cogworks

- **[cogworks#23](https://github.com/gezmodean-wow/cogworks/issues/23)** — `CreateProgressBar` primitive. Lift `UI/ProgressBar.lua` + `UI/MultiProgressBar.lua` when it lands.
- **[cogworks#27](https://github.com/gezmodean-wow/cogworks/issues/27)** — verify-package reusable workflow. Wired into Tally; close on Cogworks side once Gezmo confirms.
- **[cogworks#29](https://github.com/gezmodean-wow/cogworks/issues/29)** — verify-package backslash → forward-slash TOC normalisation. Tally worked around its own TOC.
- **flipqueue#147** — pet-battle / combat lockdown gates. Separate agent; TLY-47 closes after.

## Lead unresolved — character key normalisation (TLY-32 dig)

Spotted during TLY-32 investigation: Tally's `inspectCurrentChar` (`Core.lua:460`) builds the current character key via `UnitName .. "-" .. GetRealmName()` — Blizzard returns the display realm name *with* the space (`Ðaytrader-Area 52`), while Syndicator strips whitespace before storing (`Ðaytrader-Area52`). Result: `inRollup = false, seenBySyndicator = false` for any character on a multi-word realm even though the rollup actually contains them under the normalised key. Cogworks has a `Realms.lua` module that almost certainly already normalises this; should adopt it suite-wide. Not load-bearing for current alphas but worth fixing.

## Backlog (post-LedgerPage-bundle)

- **Character-key realm-normalisation** — adopt Cogworks `Realms.lua`. Lead from above.
- **Real-gap investigation (TLY-24)** — once Toeknee re-runs setup on alpha14+15, his Native will start capturing alongside siblings. Latest dump showed real-gap dropped 206 → 9 (mostly ah-cancel rows). If real-gap stays >0 in a future dump, file as a Native AHPosting coverage hole.
- **Authority priority audit from real data** — divergence reports accumulating now should give us tunable signal.
- **Refactor `/tally diag` onto `cw:CreateDebug`** when Cogworks v0.13's debug primitive matures (per `reference_cogworks_v013_debug.md`).

## Handy facts

- Last acknowledged scribe player-facing conventions: `2026-04-30f` (re-fetched this session, no update needed).
- Cogworks pinned at `v0.13.2` in `.pkgmeta`.
- Origin's `main` is at `959b71a`. Local matches. Remote tags up to `v0.1.0-alpha15`.
- Compressed ledger uses LibSerialize (MIT, v5) + LibDeflate (zlib, v3, level 1 since alpha15), vendored in `Libs/`. `Ledger.lua`'s `_workingMem` + `loadFromDisk` + `SaveToDisk` is the storage layer; `db()` is the lazy-load accessor every consumer uses.
- New `/tally diag` Storage section reports lib availability, blob bytes, blob entry count, dirty flag, serialise + compress timings, and legacy-on-disk indicator.
- Slash commands use `cw:RegisterSlashCommands`. Add new commands in `Core.lua`'s `RegisterSlashCommands` block.
- Debug toolkit: `ns.dbg:PrintDebug(...)`; `/tally debug` toggles live console; `/tally diag` opens copy dialog by default; `/tally diag divergence` opens divergence report; `/tally diag chat` falls back to inline chat output.
- Memory entries to read when starting: `feedback_alpha_cadence`, `feedback_no_push_without_approval`, `feedback_ui_before_ship`, `project_scope`, `feedback_player_summary`, `feedback_debug_copy_dialog`.
