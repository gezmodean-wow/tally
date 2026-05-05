# Tally — next session handoff

Picks up after the 2026-05-05 alpha14 work session. Alpha14 shipped end-to-end (committed, tagged, pushed, CI green, tester comments on TLY-32/35/24 with recovery + verification instructions).

## State

- **Branch:** `main`, working tree clean, in sync with `origin/main` at `bf297e6`.
- **HEAD commits since alpha13:**
  - `bf297e6` — `docs:` promote Unreleased → v0.1.0-alpha14.
  - `00b8e1f` — `feat(TLY-49)`: compressed blob storage for the ledger (LibSerialize + LibDeflate vendored, `db()` rewritten as lazy-load over `_workingMem`, PLAYER_LOGOUT save hook, one-shot legacy migration, `/tally diag` Storage section).
- **Tags pushed to origin:** alpha10, alpha11, alpha12, alpha13, alpha14. CI release passed for alpha14 in 29s.
- **Cogworks pinned at `v0.13.2`** in `.pkgmeta`.
- Memory at `C:\Users\gezmo\.claude\projects\C--src-tally\memory\` is current.
- `feat/ledger-compression` branch deleted post-merge.

## What shipped today

Two alphas in one session — alpha13 then alpha14, all driven by Toeknee_atx + _zpectre_'s reports.

- **alpha13** (mid-session). TLY-32 + TLY-35 + TLY-48. Per-character `TallyCharDB.tallyAcknowledged` marker for popup; defensive ordering in `onCancel`; `Sources/Native/Vendor.lua:188` `%d` → `%.0f`; Reconcile source-uniqueness gate. Mitigated TLY-35 popup symptom but not root cause; closed TLY-48 structurally (Toeknee's post-alpha13 divergence dump confirmed: field-disagreement count went 3,481 → 0).
- **alpha14** (end of session). TLY-49 — compressed blob storage. Addresses the SV constant-table-overflow root cause that alpha13 only mitigated symptomatically. Toeknee + zpectre confirmed alpha13 popup behaviour matched the per-character spec (popup once per never-acknowledged alt, then stays gone) but couldn't suppress on never-before-seen alts because TallyDB still failed to load every session. Compression fixes that by collapsing the ledger to one blob constant in the SV chunk.

## Awaiting tester verification

- **[TLY-32](https://github.com/gezmodean-wow/tally/issues/32)** — recovery cycle + verification instructions posted. Toeknee to confirm `/tally diag` Storage section reads `libs=yes`, blob round-trips cleanly across logout / login.
- **[TLY-35](https://github.com/gezmodean-wow/tally/issues/35)** — testing instructions posted. Toeknee + zpectre + Zong to confirm popup behaviour: once per never-acknowledged alt, then never again on the same alt.
- **[TLY-24](https://github.com/gezmodean-wow/tally/issues/24)** — TLY-48 verified working post-alpha13 (field-disagreement 3481 → 0). Real-gap=206 flagged as downstream of TLY-32/35/49 (Native captures gated until setup completes); should self-resolve once Toeknee gets through the recovery cycle and runs `/tally setup`.

If alpha14's recovery cycle works for affected testers:
- TLY-32 closes (Toeknee confirms cross-session round-trip).
- TLY-35 closes (Toeknee + zpectre + Zong confirm per-character one-shot).
- TLY-49 closes (Toeknee confirms blob persistence + lower SV file size).
- Real-gap signal in TLY-24 should drop on the next divergence dump.

If recovery doesn't work, watch for:
- Blob deserialise failures (`/tally diag` Storage shows `libs=yes loaded=yes mem=0` — falls back to fresh memory if blob is corrupted; user-facing one-line warning prints).
- Save failures at logout (next-session diag would show `legacyPresent=yes` carried forward, blob bytes still 0).
- LibStub load order issues (`libs=NO` in diag).

## Other tester signals still live (independent)

- **[TLY-47](https://github.com/gezmodean-wow/tally/issues/47)** — duplicate-of-flipqueue#147 (bag UI taint). Separate agent on FQ fix; closes when FQ ships.
- **[TLY-28](https://github.com/gezmodean-wow/tally/issues/28)** — Inventory tab empty (zpectre). Diag-text-please comment posted; awaiting paste.
- **[TLY-20](https://github.com/gezmodean-wow/tally/issues/20)** — Curseforge install issue from alpha1. Awaiting tester response.
- **[TLY-17](https://github.com/gezmodean-wow/tally/issues/17)** — surface "currently posted on AH" sub-line in net worth view.
- **[TLY-18](https://github.com/gezmodean-wow/tally/issues/18)** — multi-archive ledger storage + offline export/restore. Long-running.
- **TLY-39 / 40 / 41 / 42 / 43 / 44** — alpha7/8 fixes; pending in-game verification. Close after user confirms.

## Waiting on Cogworks

- **[cogworks#23](https://github.com/gezmodean-wow/cogworks/issues/23)** — `CreateProgressBar` primitive. Lift `UI/ProgressBar.lua` + `UI/MultiProgressBar.lua` when it lands.
- **[cogworks#27](https://github.com/gezmodean-wow/cogworks/issues/27)** — verify-package reusable workflow. Wired into Tally; close on cogworks side once Gezmo confirms.
- **[cogworks#29](https://github.com/gezmodean-wow/cogworks/issues/29)** — verify-package backslash → forward-slash TOC normalisation. Tally worked around its own TOC; other suite cogs may still trip.
- **flipqueue#147** — pet-battle / combat lockdown gates. Separate agent; TLY-47 closes after.

## Lead unresolved — character key normalisation (TLY-32 dig)

Spotted during TLY-32 investigation: Tally's `inspectCurrentChar` (`Core.lua:460`) builds the current character key via `UnitName .. "-" .. GetRealmName()` — Blizzard returns the display realm name *with* the space (`Ðaytrader-Area 52`), while Syndicator strips whitespace before storing (`Ðaytrader-Area52`). Result: `inRollup = false, seenBySyndicator = false` for any character on a multi-word realm even though the rollup actually contains them under the normalised key. Cogworks has a `Realms.lua` module that almost certainly already normalises this; should adopt it suite-wide. Not load-bearing for current alphas but worth fixing.

## Post-TLY-49 backlog

- **[TLY-17](https://github.com/gezmodean-wow/tally/issues/17)** — currently-posted-on-AH sub-line on Net Worth view.
- **Lift `UI/ProgressBar.lua` + `UI/MultiProgressBar.lua` to cogworks** when [cogworks#23](https://github.com/gezmodean-wow/cogworks/issues/23) lands.
- **Refactor `/tally diag` onto `cw:CreateDebug`** when cogworks v0.13's debug primitive matures.
- **Authority priority audit from real data** — once divergence reports accumulate (Toeknee's first post-alpha14 dump will have noticeably better signal once Native is no longer gated).
- **Real-gap investigation (TLY-24)** — once Toeknee re-runs setup on alpha14, his Native will start capturing alongside siblings. If real-gap stays >0, that's a Native-coverage hole worth a dedicated issue.
- **Character-key realm-normalisation** — adopt Cogworks `Realms.lua` (see lead above).

## Handy facts

- Last acknowledged scribe player-facing conventions: `2026-04-30f` (re-fetched this session, no update needed).
- Cogworks pinned at `v0.13.2` in `.pkgmeta`.
- Origin's `main` is at `bf297e6`. Local matches. Remote tags up to `v0.1.0-alpha14`.
- Compressed ledger uses LibSerialize (MIT, v5) + LibDeflate (zlib, v3), vendored in `Libs/`. Tested upstream-verbatim; do not patch unless syncing to a newer release.
- Slash commands use `cw:RegisterSlashCommands`. Add new commands in `Core.lua`'s `RegisterSlashCommands` block.
- Debug toolkit: `ns.dbg:PrintDebug(...)`; `/tally debug` toggles live console; `/tally diag` opens copy dialog by default; `/tally diag divergence` opens divergence report; `/tally diag chat` falls back to inline chat output. New `/tally diag` Storage section reports blob health.
- Memory entries to read when starting: `feedback_alpha_cadence`, `feedback_no_push_without_approval`, `feedback_ui_before_ship`, `project_scope`, `feedback_player_summary`, `feedback_debug_copy_dialog`.
