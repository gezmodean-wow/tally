# Tally — next session handoff

Picks up after the 2026-05-05 alpha13 work session. Alpha13 shipped end-to-end (committed, tagged, pushed, CI green, tester comments posted on all three covered issues).

## State

- **Branch:** `main`, working tree clean, in sync with `origin/main` at `9739054`.
- **HEAD commits since alpha12:**
  - `9739054` — `docs:` promote Unreleased → v0.1.0-alpha13.
  - `5c1e272` — `fix(TLY-32,TLY-35)`: per-char marker survives SV load failure.
  - `f3cf81c` — `fix(TLY-48)`: Reconcile clusters require source uniqueness.
- **Tags pushed to origin:** alpha10, alpha11, alpha12, alpha13. CI release flow ran for alpha13 in 40s, success.
- **Cogworks pinned at `v0.13.2`** in `.pkgmeta` (TLY-46 hotfix, COG-30 StaticPopupDialogs taint guard).
- Memory at `C:\Users\gezmo\.claude\projects\C--src-tally\memory\` is current.

## What shipped in alpha13

- **TLY-32 + TLY-35** (combined). Welcome popup re-fire root-caused to `constant table overflow in saved variables tally` (Toeknee's BugSack capture). Account-wide `TallyDB` was failing wholesale Lua-load on big SV files (>2^18 unique constants in a single chunk), wiping `setup.skipped` every session. Fix uses `TallyCharDB.tallyAcknowledged` (per-character SV, separate small file) as a load-failure-resistant marker. `ShouldShowSetupWizard` consults it as a third short-circuit. Spec shifts from "once per account, ever" → "once per character, ever." Defensive ordering applied to `onCancel` (persistence flags first, then everything else under pcall). Plus `Sources/Native/Vendor.lua:188` `%d` → `%.0f` overflow fix (separate `string.format` call that throws on big-vendor sessions even when debug is off — caller evaluates format before PrintDebug decides to emit).
- **TLY-48.** Reconcile no longer over-merges same-source rows. `Ledger.lua` `clusterGroup` adds source-uniqueness gate via parallel-tracked `clusterSources` set. Each adapter's intra-source dedup remains authoritative; Reconcile is now strictly cross-source coalescence. Closes the structural part of Toeknee's TLY-24 "Tally < TSM" complaint.

## What's queued next (TLY-49, the long pole)

**[TLY-49](https://github.com/gezmodean-wow/tally/issues/49) — compressed-serialisation storage for the ledger.** This is the proper fix for the underlying SV-overflow that TLY-32 only mitigated symptomatically. Until this ships, affected testers (Toeknee + likely others as ledgers grow) keep losing their ledger + setup state between sessions even though the popup no longer nags them. Issue body has the full plan:

- Move `TallyDB.ledger.entries` from raw table to compressed binary blob (`TallyDB.ledger.blob` + `blobMeta`).
- Vendor `LibSerialize` + `LibDeflate` into `Libs/`.
- Lazy deserialise on first read at session start; cached in-memory for the session; reserialise + recompress on `PLAYER_LOGOUT`.
- One-shot migration on first load with new code: serialise legacy `entries` array, clear it, write `blob`.
- Adapters (`Ledger:Insert` / `Query` / `Reconcile` / `InsertMany` / `Stats`) keep their current call surface — the storage layer is invisible to them.

Acceptance: 200k+ row account loads cleanly across sessions; setup, history, inventory all persist round-trip.

This is bundle-scoped, not a single-issue alpha. Plan as alpha14 or later.

## Tester signals still live (independent of alpha13)

- **[TLY-32](https://github.com/gezmodean-wow/tally/issues/32)** — popup symptom mitigated; underlying SV-overflow stays open until TLY-49 lands and Toeknee verifies cross-session round-trip.
- **[TLY-35](https://github.com/gezmodean-wow/tally/issues/35)** — fix shipped; awaiting Toeknee + zpectre verification on alpha13 across multiple alts.
- **[TLY-24](https://github.com/gezmodean-wow/tally/issues/24)** — TLY-48 fix shipped; awaiting Toeknee verification that totals move toward TSM and divergence-report field-disagreement count drops.
- **[TLY-47](https://github.com/gezmodean-wow/tally/issues/47)** — duplicate-of-flipqueue#147 (bag UI taint in raids / pet battles). Triaged; user has separate agent working on the FQ fix. Closes when FQ ships.
- **[TLY-28](https://github.com/gezmodean-wow/tally/issues/28)** — Inventory tab empty (zpectre). Diag-text-please comment posted; awaiting paste.
- **[TLY-20](https://github.com/gezmodean-wow/tally/issues/20)** — Curseforge install issue from alpha1. Retest comment posted on alpha7; still awaiting tester response.
- **[TLY-17](https://github.com/gezmodean-wow/tally/issues/17)** — surface "currently posted on AH" sub-line in net worth view. Data tracked; needs UI surface.
- **[TLY-18](https://github.com/gezmodean-wow/tally/issues/18)** — multi-archive ledger storage + offline export/restore tooling. Long-running.
- **TLY-39 / 40 / 41 / 42 / 43 / 44** — alpha7/8 fixes; pending in-game verification. Close after user confirms.

## Waiting on Cogworks

- **[cogworks#23](https://github.com/gezmodean-wow/cogworks/issues/23)** — `CreateProgressBar` primitive. `UI/ProgressBar.lua` + `UI/MultiProgressBar.lua` are Tally-local pending this; lift when it lands.
- **[cogworks#27](https://github.com/gezmodean-wow/cogworks/issues/27)** — verify-package reusable workflow. Already landed and wired into Tally's release.yml; close on cogworks side once Gezmo confirms.
- **[cogworks#29](https://github.com/gezmodean-wow/cogworks/issues/29)** — verify-package script needs to normalize backslash → forward-slash in TOC paths. Tally worked around its own TOC; other suite cogs may still trip the bug.
- **flipqueue#147** — pet-battle / combat lockdown gates + ClearCursor hardening in BankQueue. Separate agent working on it; TLY-47 closes once that ships.

## Other queued candidates (post-TLY-49)

- **[TLY-17](https://github.com/gezmodean-wow/tally/issues/17)** — currently-posted-on-AH sub-line on Net Worth view.
- **Lift `UI/ProgressBar.lua` + `UI/MultiProgressBar.lua` to cogworks** when [cogworks#23](https://github.com/gezmodean-wow/cogworks/issues/23) lands.
- **Refactor `/tally diag` onto `cw:CreateDebug`** when cogworks v0.13's debug primitive matures (per `reference_cogworks_v013_debug.md`).
- **Authority priority audit from real data** — once divergence reports accumulate.

## Lead unresolved on TLY-32 — character key normalisation

While digging into TLY-32 (the diag dump in particular), I noticed Toeknee's current character is reported as `Ðaytrader-Area 52` (with space) while Syndicator stores it as `Ðaytrader-Area52` (no space). Tally's `inspectCurrentChar` (`Core.lua:460`) builds the key via `UnitName .. "-" .. GetRealmName()` — Blizzard returns the display realm name *with* the space, while Syndicator strips whitespace before storing. Result: `inRollup = false, seenBySyndicator = false` for any character on a multi-word realm, even though the rollup actually contains that character under the normalised key.

Not load-bearing for alpha13 but worth fixing — Cogworks has a `Realms.lua` module that almost certainly already normalises this; should adopt it suite-wide. May be the source of intermittent UI weirdness on multi-word realms.

## Handy facts

- Last acknowledged scribe player-facing conventions: `2026-04-30f` (re-fetched this session, no update needed).
- Cogworks pinned at `v0.13.2` in `.pkgmeta`.
- Origin's `main` is at `9739054`. Local `main` matches. Local + remote tags up to `v0.1.0-alpha13`.
- Slash commands use `cw:RegisterSlashCommands` — auto-help renders from per-command `{ name, run, help, args, aliases }`. Add new commands as table entries in `Core.lua`'s `RegisterSlashCommands` block.
- Debug toolkit: `ns.dbg:PrintDebug(...)` for trace logging; `/tally debug` toggles the live console; `/tally diag` opens copy dialog by default; `/tally diag divergence` opens the divergence report; `/tally diag chat` falls back to inline chat output.
- Memory entries to read when starting: `feedback_alpha_cadence`, `feedback_no_push_without_approval`, `feedback_ui_before_ship`, `project_scope`, `feedback_player_summary`, `feedback_debug_copy_dialog`.
