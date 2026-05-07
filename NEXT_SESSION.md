# Tally — next session handoff

Picks up after the 2026-05-06 / 07 work session that bootstrapped suite-standards adoption, closed six tester-verified issues, surfaced zpectre's 438k-row scale ceiling, and locked the TLY-51 tiered-storage design as the alpha16 lead.

## State

- **Branch:** `main`, working tree clean (modulo this file's update), in sync with `origin/main` at `7585f91`.
- **HEAD commits since the start of the alpha15 session:**
  - `7585f91` — `chore:` bootstrap suite-standards adoption (#59) — **empty merge**, redundant duplicate of #58. Ignore in history; left as-is to avoid force-push on main.
  - `7c8432c` — `chore:` bootstrap suite-standards adoption (#58) — Standards acknowledgments block in CLAUDE.md, `shared/` file pool seeded (PR/issue templates, `pre-tag-check.sh`, `sync-standards.sh`).
  - `27a5087` — `docs:` NEXT_SESSION refreshed for alpha15.
  - `959b71a` — `fix(TLY-50)`: drop LibDeflate level 5 → 1 + save-time instrumentation in Storage diag.
  - `bf297e6` — `docs:` promote Unreleased → v0.1.0-alpha14.
  - `00b8e1f` — `feat(TLY-49)`: compressed blob storage for the ledger.
- **Tags pushed to origin:** alpha10–alpha15. CI green for all (alpha15 in 35s).
- **Cogworks pinned at `v0.13.2`** in `.pkgmeta`.
- Memory at `C:\Users\gezmo\.claude\projects\C--src-tally\memory\` is current.
- Vendored libs (alpha14): `Libs/LibSerialize/LibSerialize.lua` (MIT v5) + `Libs/LibDeflate/LibDeflate.lua` (zlib v3, level 1 since alpha15). Both upstream-verbatim — don't patch unless syncing to a newer release.
- **Standards acknowledgments** (per `CLAUDE.md`): runbooks at `2026-05-05a`, scribe player-facing at `2026-04-30f`. Re-checked this session — all current.

## What shipped / landed this session

- **Suite-standards bootstrap merged** (PR #58). CLAUDE.md acknowledgments block, issue/PR templates, `scripts/pre-tag-check.sh`, `scripts/sync-standards.sh`. Two cogworks-side bugs surfaced and need filing — see "To file against cogworks" below. Note: PR #59 was a redundant duplicate-content merge (mistake), squashed as an empty commit on main; harmless beyond log noise.
- **Six issues closed after tester verification** — TLY-32, TLY-40, TLY-41, TLY-42, TLY-43, TLY-44. All had `## Player summary` sections (TLY-32 added today; the other five already had Gez-authored summaries). All confirmed resolved by Gez via Discord at 2026-05-06 05:45–05:47Z; scribe close-announcements propagated to Discord on issue close.
- **TLY-61 filed** — Native source doesn't capture AH cancel events. Surfaced from Toeknee's alpha15 divergence dump on TLY-24: 63 of 63 real-gap entries are `ah-cancel`, all TSM-only.
- **TLY-51 issue body rewritten** as the locked design spec for tiered storage. Includes UX walkthrough (zpectre-scale fresh install + alpha14/15 migration), storage layout, three load tiers, **player-controlled sealing** (no auto-seal on logout), route-by-date initial import, monthly default + auto-weekly subdivision when row cap hits 50k, slash commands, acceptance, and a 3-phase implementation plan. Replaces the prior auto-seal-on-logout design.
- **Engineering Player updates posted** on TLY-24 (asked Toeknee for Compare export + TSM gold total) and TLY-55 (asked Toeknee for the diag — got it; see Critical findings below).

## Critical findings — drives alpha16 priority

zpectre posted his alpha15 `/tally diag` text on TLY-28 today (2026-05-07 02:58Z). Confirms what we suspected and reframes TLY-55:

- **`Ledger.rowCount = 438,795`** (TSM 209,900 + Journalator 184,954 + FlipQueue 43,921 + native 20).
- **`Memory.kb = 2,767,556`** — Tally's WoW addon footprint is ~2.7 GB on his client.
- **`[Storage]: blobBytes = 0, dirty = true, inMemoryCount = 438,795`** — alpha15 migration completed but blob hasn't been saved yet.
- Symptom (per Discord): opening the Tally main window freezes the game; Inventory tab renders empty (collateral — UI is hung, not the data).

Toeknee independently posted "Alpha15 - Logout still hangs" on TLY-55 today. Same root cause class — blob save on a 100k+ row ledger isn't fast enough. TLY-50 (compression-level drop) addressed compress cost but the freeze is upstream of compression for these accounts.

**Explore-agent perf trace (against the source tree):**

- `LedgerPage:Refresh` calls `Ledger:Reconcile()` and `Ledger:Stats()` on every tab open with no caching. Reconcile rebuilds the entire 438k-row clustered view from scratch. (`Ledger.lua:1176, 657`; `UI/LedgerPage.lua:301-312`)
- `SettingsPage:Refresh` calls `Ledger:Query({source = s.name})` once per registered source — 4 sources × 438k iterations on every Settings tab open. (`UI/SettingsPage.lua:478`)
- The freeze is per-tab (re-runs every time the user clicks back to Ledger or Settings).
- `InventoryPage:Refresh` itself doesn't touch the ledger; renders empty as collateral when the prior tab's Refresh hung the client.

User direction: **skip the alpha16-pre tab-defer hotfix; go straight to TLY-51 Phase 1.** "These guys are patient." TLY-51 closes the freeze structurally rather than papering over it.

## Tester-mirrored / waiting on tester data

- **[TLY-24](https://github.com/gezmodean-wow/tally/issues/24)** — Tally calculations lower than TSM. Posted Player update today asking Toeknee to run Compare tab (Source A=TSM, Source B=native), Export, paste, plus paste his TSM "Total Sales" gold figure for the same window. That gives the direct gold-total reconciliation we don't yet have. Decision tree depends on the Compare matched/A-only/B-only counts. Awaiting his run.
- **[TLY-28](https://github.com/gezmodean-wow/tally/issues/28)** — zpectre's Inventory empty / freeze on window open. Now understood as the same root cause as TLY-55 (UI hang on 438k-row Reconcile in a sibling tab). Closes once TLY-51 alpha16 ships and zpectre re-tests.
- **[TLY-55](https://github.com/gezmodean-wow/tally/issues/55)** — Zong's logout slowdown + Toeknee's alpha15-still-hangs report. Got the diag (438k rowCount). Closes once TLY-51 alpha16 ships.
- **[TLY-49](https://github.com/gezmodean-wow/tally/issues/49)** — alpha14 compressed-blob recovery cycle. Largely superseded by TLY-51 but still awaiting tester confirmation that the recovery cycle worked end-to-end. Close once TLY-51 ships and verifies clean cross-session round-trip.
- **[TLY-50](https://github.com/gezmodean-wow/tally/issues/50)** — alpha15 compression-level perf fix. Took effect for medium-size ledgers but inadequate for 400k+. TLY-51 makes this less load-bearing; close after TLY-51 lands.
- **[TLY-47](https://github.com/gezmodean-wow/tally/issues/47)** — duplicate of flipqueue#147 (bag UI taint). Separate agent on the FQ fix; closes when FQ ships.
- **[TLY-20](https://github.com/gezmodean-wow/tally/issues/20)** — Curseforge install issue from alpha1. Awaiting tester response (no movement since 2026-05-04).
- **[TLY-17](https://github.com/gezmodean-wow/tally/issues/17)** — surface "currently posted on AH" sub-line in net worth view. Backlog.
- **[TLY-18](https://github.com/gezmodean-wow/tally/issues/18)** — multi-archive ledger storage + offline export/restore tooling. Long-running; partially subsumed by TLY-51.

## Closed this session

- **[TLY-32](https://github.com/gezmodean-wow/tally/issues/32)** — Lua warning on character login. Player summary added; alpha14 + alpha15 fix verified.
- **[TLY-40](https://github.com/gezmodean-wow/tally/issues/40)** — warband bucket duplication. Alpha8 fix verified.
- **[TLY-41](https://github.com/gezmodean-wow/tally/issues/41)** — Compare export → copy dialog. Alpha8 verified.
- **[TLY-42](https://github.com/gezmodean-wow/tally/issues/42)** — tab strip plaintext overlap. Alpha8 verified.
- **[TLY-43](https://github.com/gezmodean-wow/tally/issues/43)** — Ledger export button. Alpha8 verified.
- **[TLY-44](https://github.com/gezmodean-wow/tally/issues/44)** — Compare slow re-enter. Alpha8 verified.

## Filed this session

- **[TLY-61](https://github.com/gezmodean-wow/tally/issues/61)** — Native source doesn't capture AH cancel events. Independent of TLY-51 but should be fixed alongside so reconciliation totals are also clean post-alpha16.

## Tomorrow's concrete work — TLY-51 Phase 1 (alpha16)

Lock-step plan from TLY-51's locked spec. All work happens on a new branch: `feat/tly-51-tiered-storage`.

1. **Branch + scaffold.** `git checkout -b feat/tly-51-tiered-storage`. Open draft PR early per branch-and-release-flow standards.
2. **Storage layer split.** New `Archive.lua` module. `Ledger.lua` separated into:
   - `_workingMem.active` (mutable, in-memory, ≤25k rows / ≤60 days)
   - `_workingMem.archives[key]` (read-only LRU cache, cap 3)
   - `TallyDB.ledger.archives[key]` and `archiveIndex` (persisted)
   - `Ledger:Query(filter)` and `Ledger:Reconcile(filter)` gain optional `filter.window = "active" | "<n>m" | "all"` (default `"active"`).
3. **Reconcile result caching** keyed on `(filter, dirty-flag)`. Invalidate on Insert / InsertMany / ClearSource. Eliminates the per-tab-open re-scan that's the current freeze cause.
4. **Migration pass** for existing alpha14/15 single-blob users: read entries from legacy blob, route by date (current month → active, prior months → staging buckets → flush to archives). Legacy blob retained until first successful new-shape save (belt-and-suspenders).
5. **Backfill flow rewrite.** `Sources/*.lua` import paths become chunked via `C_Timer.After` (~500 rows / 50ms slices). Each row routed by date; staging buckets flush as months complete or row cap hits. Initial import never inflates active set with historic rows.
6. **UI page audits.** `LedgerPage`, `SettingsPage`, `InventoryPage`, `NetWorthPage` all default to active-set only. Tab refresh hits cached Reconcile result, not full re-scan. Add header banner soft-nudge when active set exceeds soft cap.
7. **`/tally seal` slash + Settings → Maintenance button.** Manual seal trigger, confirmation dialog if cut would archive >5k rows, chunked progress toast.
8. **Synthetic stress test.** Generate a 438k-row synthetic ledger locally, run end-to-end: migration → window open → tab switches → seal → save → load. Verify acceptance criteria (window <100ms, save <200ms, seal chunked).
9. **Tag alpha16** with player update covering migration UX and new sealing model.

Phase 2 (alpha17) and Phase 3 (post-public-release) are deferred. See TLY-51 issue body for the full spec.

## Waiting on Cogworks

- **[cogworks#23](https://github.com/gezmodean-wow/cogworks/issues/23)** — `CreateProgressBar` primitive. Lift `UI/ProgressBar.lua` + `UI/MultiProgressBar.lua` when it lands.
- **[cogworks#27](https://github.com/gezmodean-wow/cogworks/issues/27)** — verify-package reusable workflow. Wired into Tally; close on Cogworks side once Gezmo confirms.
- **[cogworks#29](https://github.com/gezmodean-wow/cogworks/issues/29)** — verify-package backslash → forward-slash TOC normalisation. Tally worked around its own TOC.
- **flipqueue#147** — pet-battle / combat lockdown gates. Separate agent; TLY-47 closes after.

### To file against cogworks (surfaced this session via PR #58 review)

Both prepped but not yet filed. Quick to file tomorrow before TLY-51 work starts.

- **`sync-standards.sh check` parsing bug** — awk pulls the entire third pipe field from CLAUDE.md's `shared/` row, which includes a trailing `` `bash scripts/sync-standards.sh check` `` annotation, so the comparison never equals the bare remote code. Canonical script is in `cogworks/shared/scripts/sync-standards.sh`. Fix: trim by whitespace + dash boundary before comparing, or pin the row format to "code only".
- **Missing `.gitattributes`** — bootstrap doesn't ship one, so Windows checkouts get CRLF on `*.sh` files. Doesn't break CI (git index stores LF) but breaks local execution on Windows. Fix: add `.gitattributes` with `*.sh text eol=lf` to canonical `cogworks/shared/`.

## Lead unresolved — character key normalisation (TLY-32 dig)

Spotted during TLY-32 investigation: Tally's `inspectCurrentChar` (`Core.lua:460`) builds the current character key via `UnitName .. "-" .. GetRealmName()` — Blizzard returns the display realm name *with* the space (`Ðaytrader-Area 52`), while Syndicator strips whitespace before storing (`Ðaytrader-Area52`). Result: `inRollup = false, seenBySyndicator = false` for any character on a multi-word realm even though the rollup actually contains them under the normalised key. Cogworks has a `Realms.lua` module that almost certainly already normalises this; should adopt it suite-wide. Not load-bearing for current alphas but worth fixing alongside TLY-51 if the work touches `Core.lua:460`.

## Backlog (post-TLY-51)

- **Character-key realm-normalisation** — adopt Cogworks `Realms.lua`. Lead from above.
- **LedgerPage bundle (TLY-52 + TLY-53 + TLY-56)** — item icon + quality-color name, right-click context menu, filter chip overlap fix. ~1.5-2 days. Originally pre-empted by TLY-51 but still queued.
- **TLY-54 item-finder sidebar** — bigger refactor (~1-2 days). Independent of LedgerPage; needs design pass on the All-WoW scope.
- **TLY-61 Native AHCancel coverage hole** — fold into TLY-51 alpha16 if cheap; otherwise alpha17.
- **Real-gap investigation (TLY-24)** — depends on Toeknee's pending Compare export. Direct gold-total reconciliation closes the residual question.
- **Authority priority audit from real data** — divergence reports accumulating now should give us tunable signal.
- **Refactor `/tally diag` onto `cw:CreateDebug`** when Cogworks v0.13's debug primitive matures (per `reference_cogworks_v013_debug.md`).

## Handy facts

- Last acknowledged scribe player-facing conventions: `2026-04-30f` (re-fetched this session, no update needed).
- All cogworks runbooks acknowledged at `2026-05-05a` (re-fetched this session, no updates).
- Cogworks pinned at `v0.13.2` in `.pkgmeta`.
- Origin's `main` is at `7585f91`. Local matches. Remote tags up to `v0.1.0-alpha15`.
- Compressed ledger uses LibSerialize (MIT, v5) + LibDeflate (zlib, v3, level 1 since alpha15), vendored in `Libs/`. `Ledger.lua`'s `_workingMem` + `loadFromDisk` + `SaveToDisk` is the storage layer; `db()` is the lazy-load accessor every consumer uses.
- `/tally diag` Storage section reports lib availability, blob bytes, blob entry count, dirty flag, serialise + compress timings, and legacy-on-disk indicator.
- Slash commands use `cw:RegisterSlashCommands`. Add new commands in `Core.lua`'s `RegisterSlashCommands` block.
- Debug toolkit: `ns.dbg:PrintDebug(...)`; `/tally debug` toggles live console; `/tally diag` opens copy dialog by default; `/tally diag divergence` opens divergence report; `/tally diag chat` falls back to inline chat output.
- Memory entries to read when starting: `feedback_alpha_cadence`, `feedback_no_push_without_approval`, `feedback_ui_before_ship`, `project_scope`, `feedback_player_summary`, `feedback_debug_copy_dialog`.
