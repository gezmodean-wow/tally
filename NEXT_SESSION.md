# Tally — next session handoff

Picks up after the alpha17 ship: a focused diagnostic alpha for the gold-accounting investigation, and an agreed architecture rewrite scoped for the next several alphas.

## State

- **Branch:** `main`, working tree clean, in sync with `origin/main`.
- **Latest commit:** `647858c` — `docs(TLY-68): promote Unreleased to v0.1.0-alpha17`.
- **Tag:** `v0.1.0-alpha17` pushed; CI built and shipped to CurseForge / Wago.
- **Cogworks pinned at `v0.13.2`** in `.pkgmeta`.
- **Standards acknowledgments** (per `CLAUDE.md`): runbooks at `2026-05-05a`, scribe player-facing at `2026-04-30f`. Re-checked early in the alpha17 session — all current.

## What shipped in alpha17

A diagnostic-only alpha responding to Toeknee's alpha16 gold-mismatch report (29M actual warbank vs 37M shown; 179M actual character gold vs 108M shown). Engineering breakdown in `CHANGELOG.md`'s `## [v0.1.0-alpha17]` section; player-facing copy in `RELEASES.md`'s matching version.

- **`Gold` inspector + `/tally diag gold` subcommand** in `Core.lua`. Walks `Syndicator.API.GetAllCharacters() ∪ rollup.characters`, surfaces four flags (`money-nil`, `money-zero`, `missing-from-rollup`, `stale-rollup`), probes `GetWarband(1..4)` for multi-account Bnet setups, opens a columnar paste-friendly copy dialog. Inspector also registered with the standard `DIAG_INSPECTORS` so the data appears in `/tally diag`'s regular dump.
- **TLY-68 filed** — engineering note + diagnostic plan + architectural follow-up. Comment posted on TLY-24 asking Toeknee for `/tally networth` chat output as the immediate-data ask while alpha17 propagates.

## Waiting on Toeknee

The whole point of alpha17 is to collect data. Two asks outstanding:

1. **`/tally networth` chat output** (existing command, no need to wait for alpha17). Per-character gold + items split. Shows whether warbank-gold itself is correct (+8M Tally vs reality is likely the panel UI conflating `warband.total = gold + items`) and which characters contribute zero gold.
2. **`/tally diag gold` copy-dialog output** (alpha17). Deeper per-character probe with the four-flag breakdown.

Once we have either, we can cut the diagnosis short. Working hypothesis: warbank delta is UI conflation (not a data bug); toon delta is one or two characters silently dropped via `data.money == nil` or `projectCharacter` returning nil.

## Architecture rewrite — the agreed direction

Locked in over the alpha17 session. Multi-alpha scope; no code yet. Driving objectives, in priority order:

1. **Flipper loop must stay fast.** 20-60 character logout/login cycles, ~4-5 min per char. Per-login work that scales with total ledger size = the 60× tax that alpha16 still pays.
2. Research is allowed to be slower.
3. Universal data store for transactions + history + market info.
4. Import from other systems + record realtime superset.
5. Catch-up when other tools were running but Tally wasn't.

The framing that drops out: **sibling sources are not Tally's data.** TSM, FlipQueue, Journalator already keep their own permanent stores. Tally is the *cross-source aggregation layer*, not the universal repository. Archives become *caches of sibling-source synthesis*, evictable.

### The rewrite shape

1. **PLAYER_LOGIN registers Native, period.** No automatic `ImportFromAllSources`, no session-row insert that dirties the active blob, no automatic anything from sibling sources. Setup wizard pops if `TallyDB.setup.completed` is false.
2. **Setup wizard becomes the import controller.** Player-initiated, pausable, resumable import from siblings. Per-cycle row budget so logout during an import isn't catastrophic.
3. **Period synthesis on-demand.** Research / Lifecycle / Compare query a period; if no Tally archive yet, synthesise from siblings, persist into a slot, return. Subsequent queries hit the cache. Visible "synthesising April..." progress for periods that don't exist yet.
4. **PLAYER_LOGOUT serialises `TallyActive` only if dirty.** Active set bounded; logout cost = what changed this session.

### One-shot wipe at alpha18 first-load

Tester data is **expendable**. No grandfathering, no migration. Clean break gated by `TallyCharDB.tally_schema_version`:

- Wipe `TallyDB.ledger.{active,archives,archiveSlots,archiveIndex,nextSlot,blob,blobMeta,entries,byId}`.
- Nil every `_G[TallyA001..TallyA060]`.
- Reset `TallyDB.setup` so the wizard pops and the user opts into import explicitly.
- Preserve settings, minimap, theme, NetWorth strategy, history snapshots.

### New on-disk shape

```
TallyDB              — settings, history, slot allocation map, import watermarks
TallyCharDB          — per-character markers (welcome popup gate, schema flag)
TallyActive          — own SV file. Compressed active blob. Single string constant.
TallyA001..TallyA060 — period synthesis caches. Each slot self-contained:
                       { key, entries, byId, count, fromTs, toTs, index, savedAt }
                       index lives IN the slot — no aggregation in TallyDB.
```

The `TallyActive` split is what plugs the alpha16 constant-pool regression structurally: TallyDB's chunk no longer holds anything that grows with row count.

### Phasing

- **alpha18:** the one-shot wipe + structural splits + no-auto-import. Setup wizard's import button gets pause/resume/budget treatment. Period synthesis stays on the manual-import path; on-demand-from-view defers.
- **alpha19:** on-demand period synthesis. LRU eviction policy when slot pool fills.
- **alpha20+:** TLY-66 CSV-shaped slots — both a memory drop *and* an export-ready format for the future offline pro service.

### Open questions worth deciding before alpha18 work begins

1. **Per-cycle row budget for the manual import.** Pick a starting default (probably ~10k rows per logout-safe chunk). Easy to tune, but UI needs a number to display.
2. **Pure-Native users (no sibling addons) — archives are their only copy of pre-active data.** Future-correctness, not alpha18 blocker. Once eviction lands (alpha19+) we should gate on "are siblings still authoritative for this period?" or warn explicitly.
3. **TLY-68 architectural follow-up.** Stop being 100% dependent on Syndicator for gold. Capture `GetMoney()` at PLAYER_LOGIN into `TallyCharDB.money + moneyAt`; capture warband money at warbank-frame events. NetWorth prefers Tally-own value when fresher than Syndicator's snapshot. Lines up with TLY-31 (Tally as source of truth) — gold is the next domain after ledger. Plan to fold into the alpha18 work since we're touching capture surfaces anyway.
4. **TLY-65 (zpectre divergence freeze + empty popup).** Separate UI bug, not blocking alpha18. Worth picking up alongside if cheap.

## Live testers + tracked issues

alpha17 is the testing release for diagnosis. Tester names + channels:

- **Toeknee_atx** — primary big-ledger tester (~98k+ rows). Two open data asks: `/tally networth` chat output and (post-alpha17) `/tally diag gold` copy-dialog output. Both pin down the gold-accounting bug.
- **_zpectre_** — 438k rows. Hasn't posted alpha16 retest yet; alpha16 may also still be triggering the archiveIndex constant-pool overflow on his account, so he may not be on alpha16+ at all right now. Worth a check-in.
- **Zong** — logout perf reporter (TLY-55). alpha16 should have closed this; alpha17 changes nothing for him.

Open issues most relevant to the rewrite:

- **[TLY-24](https://github.com/gezmodean-wow/tally/issues/24)** — TSM-vs-Tally ledger comparison. Toeknee posted alpha16 Compare results; gold conversation forked to TLY-68.
- **[TLY-28](https://github.com/gezmodean-wow/tally/issues/28)** — zpectre Inventory empty / freeze. alpha16 closes this once zpectre confirms; rewrite preserves the fix.
- **[TLY-32](https://github.com/gezmodean-wow/tally/issues/32)** — alpha13/16 setup-wizard recurrence on big-tester accounts. The rewrite's clean wipe + structural split kills the underlying constant-pool overflow that was driving this.
- **[TLY-49](https://github.com/gezmodean-wow/tally/issues/49)** — superseded by TLY-51; rewrite makes it close-able.
- **[TLY-51](https://github.com/gezmodean-wow/tally/issues/51)** — alpha16 multi-SV refactor. Foundation that the rewrite builds on; index-into-slot fix lands as part of alpha18.
- **[TLY-65](https://github.com/gezmodean-wow/tally/issues/65)** — zpectre `/tally diag divergence` freeze + empty popup. Independent of the rewrite.
- **[TLY-66](https://github.com/gezmodean-wow/tally/issues/66)** — lazy-parsed CSV-format string slots. Now reframed as alpha20+ work that doubles as the export format for the future offline pro service.
- **[TLY-68](https://github.com/gezmodean-wow/tally/issues/68)** — gold accounting investigation (filed this session).

## alpha16 archiveIndex regression — superseded

The NEXT_SESSION plan from the alpha16 wrap-up was a surgical fix: relocate `archiveIndex` from TallyDB into per-slot. That fix is **not** being shipped as written. Instead, the alpha18 rewrite achieves the same structural goal (no high-cardinality data in TallyDB's chunk) via the cleaner shape — `archiveIndex` lives in slot.index and `active` lives in its own SV (`TallyActive`). Testers stay on alpha17 (or revert to alpha15) until alpha18 ships.

## Backlog (post-alpha18)

- **Character-key realm-normalisation** — adopt Cogworks `Realms.lua`. Lead from TLY-32 dig.
- **LedgerPage bundle (TLY-52 + TLY-53 + TLY-56)** — item icon + quality-color name, right-click context menu, filter chip overlap fix.
- **TLY-54 item-finder sidebar** — bigger refactor. Independent of LedgerPage; needs design pass on the All-WoW scope.
- **TLY-61 Native AHCancel coverage hole** — fold into a future alpha if cheap.
- **Authority priority audit from real data** — divergence reports accumulating now should give us tunable signal.
- **Refactor `/tally diag` onto `cw:CreateDebug`** when Cogworks v0.13's debug primitive matures.

## Cross-cog (waiting on Cogworks)

- **[cogworks#23](https://github.com/gezmodean-wow/cogworks/issues/23)** — `CreateProgressBar` primitive. Lift `UI/ProgressBar.lua` + `UI/MultiProgressBar.lua` when it lands.
- **[cogworks#27](https://github.com/gezmodean-wow/cogworks/issues/27)** — verify-package reusable workflow. Wired into Tally; close on Cogworks side once Gezmo confirms.
- **[cogworks#29](https://github.com/gezmodean-wow/cogworks/issues/29)** — verify-package backslash → forward-slash TOC normalisation.
- **[cogworks#34](https://github.com/gezmodean-wow/cogworks/issues/34)** — `sync-standards.sh check` parsing bug.
- **[cogworks#35](https://github.com/gezmodean-wow/cogworks/issues/35)** — `.gitattributes` for `*.sh eol=lf`.

## Handy facts

- Last acknowledged scribe player-facing conventions: `2026-04-30f`.
- All cogworks runbooks acknowledged at `2026-05-05a`.
- Cogworks pinned at `v0.13.2` in `.pkgmeta`.
- alpha16 multi-SV slots (`TallyA001`..`TallyA060`) declared in `tally.toc`. The alpha18 rewrite keeps this layout but adds `TallyActive` as a sibling SV.
- Memory entries to read when starting: `project_architecture_rewrite_plan`, `project_pro_service_direction`, `feedback_alpha_cadence`, `feedback_no_push_without_approval`, `feedback_ui_before_ship`, `feedback_player_summary`, `feedback_debug_copy_dialog`.
