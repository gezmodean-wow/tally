# Tally — next session handoff

Picks up after the multi-session work that delivered alpha16 — the TLY-51 tiered-storage refactor with multi-SV slot architecture and async-chunked legacy-blob loading.

## State

- **Branch:** `main`, working tree clean, in sync with `origin/main` at the alpha16 merge commit.
- **Tag:** `v0.1.0-alpha16` pushed; CI built and shipped to CurseForge / Wago.
- **Cogworks pinned at `v0.13.2`** in `.pkgmeta`.
- **Standards acknowledgments** (per `CLAUDE.md`): runbooks at `2026-05-05a`, scribe player-facing at `2026-04-30f`. Re-checked early in the alpha16 session — all current.
- Memory at `C:\Users\gezmo\.claude\projects\C--src-tally\memory\` is current.
- Vendored libs unchanged: `Libs/LibSerialize/LibSerialize.lua` (MIT v5) + `Libs/LibDeflate/LibDeflate.lua` (zlib v3, level 1). LibDeflate is now only used for active-blob compression and legacy alpha14/15 read paths; archive slots are uncompressed raw tables.

## What shipped in alpha16

The full breakdown lives in `CHANGELOG.md`'s `## [v0.1.0-alpha16]` section and `RELEASES.md`'s player-facing version. Headlines:

- **Multi-SV slot storage.** Each archive in its own SavedVariables slot (`TallyA001` … `TallyA060`). Each slot is its own Lua chunk → own constant pool → no overflow risk regardless of total ledger size. Per-archive write is a table assignment (instant); per-archive read is a global lookup (instant).
- **Async-chunked legacy-blob load at PLAYER_LOGIN.** The 30-50s synchronous deserialise that alpha14/15 → alpha16 upgraders would have hit is now chunked via `LibSerialize:DeserializeAsync` with a 1024-item yieldCheck. Game stays responsive throughout the load (~30 fps on slower hardware, no input-thread block).
- **Routed-by-date backfill** for the wizard's sibling-source import. Current-month rows go to active; prior-month rows accumulate in staging buckets and flush to slots after all sources complete. A 438k-row TSM CSV import never inflates the active set.
- **Reconcile result cache** keyed on filter contents; eliminates the per-tab-open clustered re-scan that was the dominant freeze cause.
- **`/tally seal`** + Settings → Maintenance button + main-frame "Sealing recommended" header banner. User-driven shrink of the active set when it exceeds the soft cap.
- **Compare opt-in for full-history scope** via "Include archives" checkbox; default active-only keeps Compare snappy on big ledgers.
- **`/tally seed`** synthetic stress harness — `seed N`, `seed legacy N`, `seed clear`. Lets us reproduce zpectre/Toeknee-scale loads on a local install.

## Live testers + feedback channels

alpha16 went out as the testing release. Tester names + channels per the existing flow:

- Toeknee_atx — primary big-ledger tester. Pre-fix had ~98k rows, expected to be the first to validate the legacy-blob async load + migration end-to-end.
- _zpectre_ — 438k rows and counting. The freeze cause we've been designing around. Critical alpha16 validator.
- Zong — logout perf reporter on TLY-55. Logouts should now be bounded by active-set size; archives are write-once after migration.
- Idiot, others — opportunistic.

Issues to watch for in tester reports on alpha16:
- **Memory footprint.** alpha16 archives are raw Lua tables, fully resident. A 200k-row tester reported ~100 MB Tally memory (vs ~5 MB on alpha15). Acceptable for shipping; queued as TLY-66 for the next-pass optimisation (lazy-parsed string slots).
- **First logout after migration cost.** The initial logout writes 30-60 fresh slot SV files — WoW's serialiser handles this, not Tally's, so it's outside our optimisation surface but visible to the user as "Logging out…" hanging for a few seconds.
- **Frame rate during legacy load on slower hardware.** Designed for ~30 fps; if a tester reports lower, the next lever is dropping yieldCheck from 1024 to 512 items per yield.

## Tester-mirrored / waiting on data

- **[TLY-24](https://github.com/gezmodean-wow/tally/issues/24)** — Toeknee's TSM vs Tally undercount + Compare freeze. alpha16's filter.window default eliminates the Compare freeze; the Compare run we asked for can finally happen. Awaiting his post-alpha16 retest.
- **[TLY-28](https://github.com/gezmodean-wow/tally/issues/28)** — zpectre's Inventory empty / freeze on window open. Same root cause as TLY-55 (UI hang on Reconcile over 438k rows). alpha16 closes this via the Reconcile cache + active-only default.
- **[TLY-55](https://github.com/gezmodean-wow/tally/issues/55)** — Zong's logout slowdown + Toeknee's alpha15-still-hangs report. alpha16 bounds logout cost to the active-set serialise; closes once testers confirm.
- **[TLY-49](https://github.com/gezmodean-wow/tally/issues/49)** — alpha14 compressed-blob recovery cycle. Largely superseded by TLY-51; closes once Toeknee or zpectre confirms the alpha16 load path works on real legacy data.
- **[TLY-50](https://github.com/gezmodean-wow/tally/issues/50)** — alpha15 compression-level perf fix. Made less load-bearing by alpha16's tiered storage; close after alpha16 ships.
- **[TLY-47](https://github.com/gezmodean-wow/tally/issues/47)** — flipqueue#147 duplicate (bag UI taint). Separate agent; closes when FQ ships.
- **[TLY-20](https://github.com/gezmodean-wow/tally/issues/20)** — Curseforge install issue from alpha1. Awaiting tester response.
- **[TLY-17](https://github.com/gezmodean-wow/tally/issues/17)** — surface "currently posted on AH" sub-line in net worth view. Backlog.
- **[TLY-18](https://github.com/gezmodean-wow/tally/issues/18)** — multi-archive ledger storage + offline export/restore tooling. Most of this landed in alpha16; remaining bits (offline export, archive comparison view) are post-alpha16.

## Filed during the alpha16 work

- **[TLY-66](https://github.com/gezmodean-wow/tally/issues/66)** — Lazy-parsed string slots to drop archive memory footprint ~20×. Phase 2 follow-up; alpha16 raw-table slots solve the freeze structurally but at high in-memory cost. The TSM-style CSV-format slot proposal documented in detail in the issue body.
- **[cogworks#34](https://github.com/gezmodean-wow/cogworks/issues/34)** — `sync-standards.sh check` parsing bug. Surfaced from PR #58.
- **[cogworks#35](https://github.com/gezmodean-wow/cogworks/issues/35)** — suite-standards bootstrap missing `.gitattributes`. Surfaced from PR #58.

## Player-facing follow-ups beyond TLY-66

- **Lifecycle / Research panels gain "Include archives" option.** Currently default to active-only; deep-history queries miss data for old items. Phase 2 work to lazy-load relevant archives per item-history query (matches the spec's Phase 2 plan in TLY-51).
- **NetWorth chart pre-computed monthly aggregates from `archiveIndex.monthlyAggregates`.** Already populated at archive-write time; rendering is the missing piece. Phase 3.
- **Per-archive Compare scope (the "swap active out, compare an archive" UX Gez floated).** Multi-SV makes this clean: load one slot, query just that slot. Spec it as Phase 2 follow-up if testers want it.
- **`/tally archive list / load / unload`** slash family. Diagnostic surface for power users to inspect / flush / preload archives. Spec'd in TLY-51 issue body but deferred from alpha16.
- **Optional auto-seal triggers.** Settings checkboxes for "seal on idle / `/logout` / before `/reload`". Off by default.
- **Footer indicator during migration / backfill.** Currently chat-only; a UI surface would help less-technical users.

## Waiting on Cogworks

- **[cogworks#23](https://github.com/gezmodean-wow/cogworks/issues/23)** — `CreateProgressBar` primitive. Lift `UI/ProgressBar.lua` + `UI/MultiProgressBar.lua` when it lands.
- **[cogworks#27](https://github.com/gezmodean-wow/cogworks/issues/27)** — verify-package reusable workflow. Wired into Tally; close on Cogworks side once Gezmo confirms.
- **[cogworks#29](https://github.com/gezmodean-wow/cogworks/issues/29)** — verify-package backslash → forward-slash TOC normalisation. Worked around in Tally.
- **[cogworks#34](https://github.com/gezmodean-wow/cogworks/issues/34)** — `sync-standards.sh check` parsing bug (filed this session).
- **[cogworks#35](https://github.com/gezmodean-wow/cogworks/issues/35)** — `.gitattributes` for `*.sh eol=lf` (filed this session).
- **flipqueue#147** — pet-battle / combat lockdown gates. Separate agent; TLY-47 closes after.

## Lead unresolved — character key normalisation (TLY-32 dig)

Still applies. Tally's `inspectCurrentChar` (`Core.lua:460`) builds the current character key via `UnitName .. "-" .. GetRealmName()` — Blizzard returns the display realm name with the space (`Ðaytrader-Area 52`), while Syndicator strips whitespace before storing (`Ðaytrader-Area52`). Result: `inRollup = false, seenBySyndicator = false` for any character on a multi-word realm even though the rollup actually contains them under the normalised key. Cogworks `Realms.lua` likely has a normaliser; should adopt it suite-wide.

## Backlog (post-alpha16)

- **TLY-66** — lazy-parsed string slots (the next big alpha16 follow-up).
- **Character-key realm-normalisation** — adopt Cogworks `Realms.lua`. Lead from TLY-32 dig.
- **LedgerPage bundle (TLY-52 + TLY-53 + TLY-56)** — item icon + quality-color name, right-click context menu, filter chip overlap fix. ~1.5-2 days.
- **TLY-54 item-finder sidebar** — bigger refactor (~1-2 days). Independent of LedgerPage; needs design pass on the All-WoW scope.
- **TLY-61 Native AHCancel coverage hole** — fold into a future alpha if cheap.
- **Real-gap investigation (TLY-24)** — depends on Toeknee's pending Compare export now that the freeze is fixed.
- **Authority priority audit from real data** — divergence reports accumulating now should give us tunable signal.
- **Refactor `/tally diag` onto `cw:CreateDebug`** when Cogworks v0.13's debug primitive matures (per `reference_cogworks_v013_debug.md`).

## Handy facts

- Last acknowledged scribe player-facing conventions: `2026-04-30f`.
- All cogworks runbooks acknowledged at `2026-05-05a`.
- Cogworks pinned at `v0.13.2` in `.pkgmeta`.
- alpha16 introduced multi-SV slots (`TallyA001`..`TallyA060`) declared in `tally.toc`. Bump `Archive.SLOT_COUNT` + the TOC declarations together if 60 isn't enough.
- `Archive:Save / SaveAsync / Load / LoadAsync` are all synchronous-but-fast for slot-resident archives. The async variants exist for API compatibility with the chunked flush path.
- Memory entries to read when starting: `feedback_alpha_cadence`, `feedback_no_push_without_approval`, `feedback_ui_before_ship`, `project_scope`, `feedback_player_summary`, `feedback_debug_copy_dialog`.
