# Tally — next session handoff

Picks up after the alpha18 ship: active-only baseline + TLY-68 gold capture + sibling-source probe live; first real-world tester data in hand and a clear alpha19 plan locked.

## State

- **Branch:** `main`, one commit ahead of `origin/main` (`ae00460` — warband row UI split, rides with alpha19).
- **Latest commit:** `ae00460` — `fix(TLY-68): split warband row in NetWorthPage into gold + items`.
- **Latest tag:** `v0.1.0-alpha18` shipped 2026-05-09; CI built + pushed to CurseForge / Wago successfully.
- **Cogworks pinned at `v0.13.2`** in `.pkgmeta`.
- **Standards acknowledgments** (per `CLAUDE.md`): runbooks at `2026-05-05a`, scribe player-facing at `2026-04-30f`. Both checked early in the alpha18 ship session — all current.

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

### Anchor work

- **[TLY-69](https://github.com/gezmodean-wow/tally/issues/69) — multi-source gold authority + provenance.** Filed 2026-05-11. Each gold-bearing source gets `:ProbeCharGold(charKey)` returning `{ money, moneyAt, source }`. `Inventory.preferredCharGold` walks them, picks the freshest by `moneyAt`. Sources for v1: `tally-native` (alpha18 capture, already wired), `syndicator`, `tsm` (TSM Accounting's per-char goldLog — same CSV-string shape as the existing csvSales/csvBuys Tally already parses). Stretch: `accountant` adapter. `/tally diag gold` gains a per-source column + provenance "source" column. Same authority pattern Ledger:Reconcile uses today, ported to gold.
- **Manual import controller in setup wizard.** Was in the original alpha19 plan. Pause/resume/per-cycle row budget. Starting budget 10k rows per cycle; testers refine via the sibling probe data (`/tally diag sources`) on actual rosters.
- **On-demand period synthesis.** When Research/Lifecycle/Compare query a period without a Tally archive, synthesise from siblings, persist into a slot, return. LRU eviction when slot pool fills.

### Rides along

- **`ae00460` warband row UI split.** Committed locally, ships with alpha19's tag.

### Sequencing

Tackle TLY-69 first (sharpest improvement to per-character gold accuracy; doesn't require manual import flow); then manual import controller (now backed by real probe data); then period synthesis. Warband UI split travels with whatever ships first.

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

- alpha18 shipped 2026-05-09; `ae00460` (warband UI split) sits local on `main` waiting for alpha19.
- Last acknowledged scribe player-facing conventions: `2026-04-30f`.
- All cogworks runbooks acknowledged at `2026-05-05a`.
- Cogworks pinned at `v0.13.2` in `.pkgmeta`.
- `TallyActive` declared in `tally.toc` alongside `TallyA001..TallyA060`.
- Memory entries to read when starting: `project_architecture_rewrite_plan` (now reflects alpha19 scope), `project_pro_service_direction`, `feedback_alpha_cadence`, `feedback_no_push_without_approval`, `feedback_ui_before_ship`, `feedback_player_summary`, `feedback_debug_copy_dialog`.
