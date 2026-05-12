# Tally — next session handoff

Picks up mid-alpha19. TLY-70 (output-channel consolidation) and TLY-69 v1 (multi-source gold authority) both landed and pushed to `origin/main`; the alpha19 ship awaits manual import controller + on-demand period synthesis, plus an upstream Cogworks fix for the debug-console crash.

## State

- **Branch:** `main`, fully synced with `origin/main`.
- **Latest commit:** `1d4235d` — `feat(TLY-69): multi-source gold authority — Tally / Syndicator / TSM`.
- **Latest tag:** `v0.1.0-alpha18` shipped 2026-05-09. No alpha19 tag yet — work in flight.
- **Cogworks pinned at `v0.13.2`** in `.pkgmeta`. Will need a bump to whatever ships with cogworks#56's fix.
- **Standards acknowledgments** (per `CLAUDE.md`): runbooks at `2026-05-05a`, scribe player-facing at `2026-04-30f`. Both current.

## Blockers / waiting

- **[cogworks#56](https://github.com/gezmodean-wow/cogworks/issues/56)** — `CreateDebugConsole` crashes on first open because `CreateTabPanel` eagerly activates the first tab before `Debug.lua`'s `f._build*` methods are defined. `/tally debug` is unusable until a Cogworks tag ships the proposed `lazy = true` opt on `CreateTabPanel` + explicit `SetActiveTab` at the bottom of `CreateDebugConsole`. Tally confirmed the bug on 2026-05-11; comment added to the issue.

## What shipped in alpha18

The structural rewrite, phase 1. Three thematic commits, one ship tag.

- **`47b4654` — alpha18 active-only baseline.** `TallyActive` SV split (active blob in its own SV file, TallyDB stays free of high-cardinality data — kills the constant-pool overflow that haunted alpha13/16); dual schema gate (account-wide `TallyDB.tally_schema_version` for the ledger wipe, per-char `TallyCharDB.tally_schema_version` for the `tallyAcknowledged` clear); auto-import + legacy-blob migration kick removed from PLAYER_LOGIN; setup wizard collapses to 3 steps (Welcome / Strategy / History) with no sibling-source import on Finish; 420+ lines of dead step builders + helpers deleted from `UI/SetupWizard.lua`.
- **`64f41de` — TLY-68 gold capture surfaces.** `Inventory:CaptureCurrentCharGold` writes `TallyDB.charGold[charKey]` from `GetMoney()` at PLAYER_LOGIN + every `PLAYER_MONEY` event; `Inventory:CaptureWarbandGold` writes `TallyDB.warbandGold` from `C_Bank.FetchDepositedMoney(Enum.BankType.Account)` on account-banker frame open (Syndicator's `GetWarband(1).money` as fallback); `projectCharacter` / `projectWarbandBank` prefer Tally's captured value over Syndicator's snapshot.
- **`f91cf88` — sibling-source metadata probe.** Each sibling adapter (FlipQueue, TSM, Journalator) gains a `:ProbeMetadata()` returning `{ count, fromTs, toTs, byMonth, notes }`. `/tally diag sources` rolls them into a copy-dialog with per-month distribution + 60-day window peak — the simulated-import substitute for sizing alpha19's per-cycle row budget.
- **`cb83fa6` — CHANGELOG + RELEASES** for alpha18.

## Known wart on upgrade path

Upgraders coming from alpha13/16/17 with a pre-rewrite SV file too large to parse hit a one-time `1x Error loading WTF/Account/<acct>/SavedVariables/tally.lua: constant table overflow` on first alpha18 login. **Recoverable.** WoW parses the SV file before any addon code runs, so the wipe gate can't intercept — the parse fails wholesale, TallyDB stays nil, Tally inits it to `{}`, the wipe gate fires against an empty table, and the next PLAYER_LOGOUT writes a small clean replacement. Toeknee confirmed: second login is clean.

Reason there's no code-level avoidance: WoW's SV parse runs before any addon hook. The only true workaround is manually deleting `tally.lua` before installing alpha18, which we didn't document on the ship. Open backlog item: optional post-wipe chat-line softener for testers who saw the error (acknowledges the upgrade, contextualises the popup). Not blocking alpha19.

## Tester data + diagnoses

Two testers ran alpha17 diag (per Toeknee's ask) + alpha18 diag (Toeknee on alpha18, zong still on alpha17).

### Toeknee (alpha18, big roster — 68 chars)

Filed comment summarising the diagnosis: https://github.com/gezmodean-wow/tally/issues/24#issuecomment-4417633107.

- **Warband gold = 29.2M, matches reality to the copper.** The 37M he originally reported was the Net Worth panel showing `warband.total` (gold + items combined) as the Warband row's headline. UI label issue, not a data bug. **Fix committed locally** (`ae00460`) — warband split into "Warband — gold" + "Warband — items" rows, each gated on `> 0`, both click-through to the warband inventory view. Rides with alpha19.
- **Toon gold gap of ~63M against his 179M reality figure.** Diagnostic shows 27 of his 68 characters reporting 0 gold, with Syndicator + Tally capture + rollup all agreeing on 0. Interpretation: those characters haven't logged in since he installed Syndicator + Tally + FlipQueue together. None of the addons have ever captured their gold balance. Fast path is logging into each affected char with addons loaded; no-cycling path is TLY-69 (TSM goldLog as a third source).
- **Memory: 6.5 MB** post-rewrite, down from ~100 MB on alpha16 with full-history loaded. Active-only baseline doing its job.

### zong (alpha17, smaller roster — 53 chars)

- `/tally diag gold` shows rollup total 135K vs Syndicator total 90K, delta −45K (rollup higher). Per-char inversions both directions (`DerRatvonDalaran` rollup 19,427g vs Syndicator 999g = ≈18.4k phantom; others smaller).
- Diagnosis: stale `TallyDB.inventoryRollup` from a Rebuild before he moved gold between alts. alpha18 capture fixes this directly — once each affected char cycles through an alpha18 login, the captured value overrides Syndicator's stale snapshot.
- Hasn't retested on alpha18 yet (still on alpha17 last we heard). No outstanding ask.

### Decision: "trust the mechanism, move on"

User-confirmed (2026-05-11). No further Toeknee or zong follow-up ask. alpha18 capture is the mechanism; cycling characters is the path to convergence. If testers want validation, they can re-run `/tally diag gold` themselves — we're not actively soliciting another round.

## alpha19 plan

### Landed (on `main`, awaiting tag)

- **[TLY-70](https://github.com/gezmodean-wow/tally/issues/70) — output-channel consolidation.** 6 commits (`c205ae2`, `a8bdd8e`, `37b0715`, `e523b48`, `19a7211`, `13e3e58`). Every player-visible output routes through `ns.Output`: brief status → toast (auto-mirrored to debug log), inspectable detail → copy-dialog, engineering → `ns.dbg:PrintDebug` → debug console. Chat output (`/tally networth`, explicit opt-ins) goes via `ns.Output:ChatRaw` so every chat line mirrors to the debug log automatically — `/tally debug` becomes the always-copyable archive even when chat frame filters block selection. `/tally diag chat` + `/tally research-chat` rerouted to copy-dialog (diagnostic content belongs in inspectable substrate). 7 documented exceptions remain (pre-Cogworks init, defensive fallbacks, vendored libs).
- **[TLY-69](https://github.com/gezmodean-wow/tally/issues/69) v1 — multi-source gold authority.** Commit `1d4235d`. Each gold-bearing source registers a probe with `Inventory`'s gold-source registry; `preferredCharGold` walks the registry and picks freshest by `moneyAt`. Sources for v1: `tally-native` (alpha18 capture), `syndicator` (with rollup `lastFullScan` as freshness proxy since the API has no per-char timestamp), `tsm` (parses the per-character `goldLog` CSV under `TradeSkillMasterDB.s@<char> - <faction> - <realm>@internalData@goldLog`). `/tally diag gold` shows per-source columns + chosen-source provenance. Closes the path Toeknee's 63M toon-gold gap was sitting on.
- **`ae00460` warband row UI split** + **`cb83fa6` alpha18 changelog/release docs**. Both pushed.

### Still to do for alpha19 ship

- **Manual import controller in setup wizard.** Pause/resume/per-cycle row budget. Starting budget 10k rows per cycle; testers refine via the sibling-source probe data (`/tally diag sources`) on actual rosters. Substantial UI + state-machine work.
- **On-demand period synthesis.** When Research/Lifecycle/Compare query a period without a Tally archive, synthesise from siblings, persist into a slot, return. LRU eviction when slot pool fills.
- **Bump Cogworks pin** once cogworks#56 ships a tag with the `CreateTabPanel` `lazy` opt — unblocks `/tally debug`.
- **TLY-69 v2 (stretch)**: optional Accountant_NWB / Classic adapter; multi-source warband gold (TSM doesn't track warband, so the value-add is small — defer unless a tester surfaces something).
- **CHANGELOG / RELEASES `## Unreleased`** entries for the work above (currently blank).

### Sequencing

Manual import controller is the chunky one — needs design pass on pause/resume UX. Period synthesis builds on the import controller (similar pipeline shape). The Cogworks pin bump is opportunistic — do it when the upstream tag ships, no schedule pressure.

## Open decisions before alpha19 work begins

1. **TSM `goldLog` storage shape — verify.** TLY-69 assumes TSM Accounting stores per-character gold in `TradeSkillMasterDB.r@<realm>@internalData@goldLog` as a CSV string mirroring the csvSales/csvBuys shape. Worth confirming against the TSM source before wiring the adapter — could be a different key or a different format. Spot-check on Toeknee's or zong's SV would settle it.
2. **Per-cycle row budget default.** 10k still the assumption from the alpha18 session. Tester probe data (sibling-source row distributions from `/tally diag sources`) will inform but isn't blocking — pick a starting number, ship, tune.
3. **TLY-65 (zpectre divergence freeze + empty popup).** Still independent of the rewrite. Pick up in alpha19 if cheap, otherwise defer to alpha20.

## Live testers + tracked issues

- **Toeknee_atx** — primary big-roster tester (68 chars, ~6.5 MB on alpha18). alpha18 first-load overflow recovered cleanly; gold diagnosis posted on TLY-24. No outstanding asks.
- **zong** — 53-char roster on alpha17 (not yet retested on alpha18). Same gold-staleness pattern at smaller scale. No outstanding asks (per "trust the mechanism").
- **_zpectre_** — 438k rows on alpha15 last we knew. Hasn't posted on alpha16/17/18. Worth a check-in but not blocking.
- **Zong** (logout perf, [TLY-55](https://github.com/gezmodean-wow/tally/issues/55)) — should be closed by alpha18's active-only baseline; no recent feedback.

Open issues most relevant to alpha19:

- **[TLY-24](https://github.com/gezmodean-wow/tally/issues/24)** — TSM-vs-Tally ledger comparison. Gold conversation forked to TLY-68. Stays open until alpha19 lands and totals converge.
- **[TLY-28](https://github.com/gezmodean-wow/tally/issues/28)** — zpectre Inventory empty / freeze. Awaiting zpectre confirmation.
- **[TLY-31](https://github.com/gezmodean-wow/tally/issues/31)** — Tally as source of truth. Gold is the next domain after ledger — TLY-69 is the implementation of that for gold.
- **[TLY-65](https://github.com/gezmodean-wow/tally/issues/65)** — zpectre divergence freeze. Independent.
- **[TLY-66](https://github.com/gezmodean-wow/tally/issues/66)** — CSV-shaped slots. alpha20+.
- **[TLY-67](https://github.com/gezmodean-wow/tally/issues/67)** — minimap forgets placement. Small bug, alpha19+.
- **[TLY-68](https://github.com/gezmodean-wow/tally/issues/68)** — gold accounting investigation. Foundation shipped in alpha18; closes once alpha19 lands TLY-69.
- **[TLY-69](https://github.com/gezmodean-wow/tally/issues/69)** — multi-source gold authority. alpha19 anchor.
- **[TLY-70](https://github.com/gezmodean-wow/tally/issues/70)** — output-channel consolidation (chat → toasts / debug log / copy dialog). alpha19 scope; may split into multi-alpha cohorts.

## Backlog (post-alpha19)

- **Character-key realm-normalisation** — adopt Cogworks `Realms.lua`. Lead from TLY-32 dig.
- **LedgerPage bundle (TLY-52 + TLY-53 + TLY-56)** — item icon + quality-color name, right-click context menu, filter chip overlap fix.
- **[TLY-54](https://github.com/gezmodean-wow/tally/issues/54)** — item-finder sidebar. Bigger refactor, needs design pass on the All-WoW scope.
- **[TLY-61](https://github.com/gezmodean-wow/tally/issues/61)** — Native AHCancel coverage hole.
- **Refactor `/tally diag` onto `cw:CreateDebug`** when Cogworks v0.13's debug primitive matures.
- **Optional post-wipe chat softener** for upgraders who hit the alpha18 first-load overflow error. Not urgent.

## Cross-cog (waiting on Cogworks)

- **[cogworks#23](https://github.com/gezmodean-wow/cogworks/issues/23)** — `CreateProgressBar` primitive. Lift `UI/ProgressBar.lua` + `UI/MultiProgressBar.lua` when it lands.
- **[cogworks#27](https://github.com/gezmodean-wow/cogworks/issues/27)** — verify-package reusable workflow.
- **[cogworks#29](https://github.com/gezmodean-wow/cogworks/issues/29)** — verify-package backslash → forward-slash TOC normalisation.
- **[cogworks#34](https://github.com/gezmodean-wow/cogworks/issues/34)** — `sync-standards.sh check` parsing bug.
- **[cogworks#35](https://github.com/gezmodean-wow/cogworks/issues/35)** — `.gitattributes` for `*.sh eol=lf`.

## Handy facts

- alpha18 shipped 2026-05-09. alpha19 in flight: TLY-69 v1 + TLY-70 on `origin/main` since 2026-05-11.
- Last acknowledged scribe player-facing conventions: `2026-04-30f`.
- All cogworks runbooks acknowledged at `2026-05-05a`.
- Cogworks pinned at `v0.13.2` in `.pkgmeta`. Bump needed when cogworks#56's fix tags.
- `TallyActive` declared in `tally.toc` alongside `TallyA001..TallyA060`. `Util/Output.lua` is the channel router for all user-visible output.
- Memory entries to read when starting: `project_architecture_rewrite_plan` (reflects alpha19 mid-flight), `project_pro_service_direction`, `feedback_alpha_cadence`, `feedback_no_push_without_approval`, `feedback_ui_before_ship`, `feedback_player_summary`, `feedback_output_channels` (TLY-70 channel taxonomy).
- TSM goldLog storage shape verified in live SV: `s@<char> - <faction> - <realm>@internalData@goldLog`, value = `"minute,copper\n<minute>,<copper>\n..."` (balance snapshots, not deltas).
