# Tally — next session handoff

Picks up where the 2026-05-01 session left off after shipping `v0.1.0-alpha4`.

## What landed in alpha4

Five commits since alpha3 (all on `main`, tagged `v0.1.0-alpha4`):

- **`e134410`** — `.pkgmeta` `manual-changelog` directive + `RELEASES.md` skeleton; CLAUDE.md documents the dual-changelog discipline
- **`9ba922c`** — `RELEASES.md` backfilled with player-facing alpha1/2/3 notes
- **`fe1363e`** — `MainFrame` resizable (drag bottom-right grip; bounds 600×360 to 1600×1100; persists in `TallyDB.ui.mainFrame.size`); Compare tab gains `Tally Ledger (all)` virtual source
- **`4fcda51`** — `/tally diag` one-shot diagnostic dump command (Tally-local pending Cogworks v0.13's debug primitive)
- **`0c3dddc`** — TLY-24 immediate wins: bonus-ID price fallback in `Pricing:GetUnitValue`; per-source skip counters on every adapter; raw Syndicator gold-field probe added to `/tally diag`

## What's blocking on tester input

Two open tickets have player updates posted (will mirror to Discord) asking for `/tally diag` output:

- **[TLY-24](https://github.com/gezmodean-wow/tally/issues/24)** — Toeknee's TSM-vs-Tally discrepancy. Bonus-ID fallback shipped blind; need his diag to confirm the warband/per-char gold field name issue.
- **[TLY-28](https://github.com/gezmodean-wow/tally/issues/28)** — Inventory tab shows empty after lag. Need diag + wizard-completion confirmation.

When their diag arrives, fixes are likely one-line each in `Inventory/Ownership.lua` (gold field name) or wizard completion flow.

## What to start tomorrow

**Pivot to TLY-31 Phase A** — Tally as source of truth, native event capture parity for the high-value sibling sources.

Phase A scope (per [TLY-31](https://github.com/gezmodean-wow/tally/issues/31)):

- AH posting (`PostItem` / `PostCommodity` / `PostAuction` hooks) → `ah-deposit` rows from Native instead of Journalator-only
- AH cancel events → `ah-cancel` from Native
- Vendor sell / buy via `MERCHANT_SHOW` + bag-delta tracking → `vendor-sell` / `vendor-buy` from Native
- Repairs via money-delta around `RepairAllItems` → `repair` from Native
- Mail send / receive (non-AH) → `mail-send` / `mail-receive` from Native

File-per-bucket layout: `Sources/Native/AHPosting.lua`, `Sources/Native/Vendor.lua`, `Sources/Native/Repair.lua`, `Sources/Native/Mail.lua` — keep `Sources/Native.lua` as the orchestrator that registers them all.

Sibling adapters (TSM, FlipQueue, Journalator) stay as-is for now; they get demoted to backfill-only in Phase B once Native parity is proven.

## Other open issues, in priority order

- **[TLY-29](https://github.com/gezmodean-wow/tally/issues/29)** — capture-layer rigor (loss accounting partially shipped via skip counters; kind router + structured field map still pending). Likely to land alongside Phase A as we touch the adapters.
- **[TLY-30](https://github.com/gezmodean-wow/tally/issues/30)** — view-layer reconciliation. Depends on TLY-29 completion. Probably alpha5+.
- **[TLY-22](https://github.com/gezmodean-wow/tally/issues/22)**, **[TLY-23](https://github.com/gezmodean-wow/tally/issues/23)**, **[TLY-25](https://github.com/gezmodean-wow/tally/issues/25)**, **[TLY-26](https://github.com/gezmodean-wow/tally/issues/26)**, **[TLY-27](https://github.com/gezmodean-wow/tally/issues/27)** — all shipped in alpha3; ready to close once tester verifies the alpha4 build doesn't regress them. Worth a sweep with `## Player summary` comments per scribe conventions.

## Waiting-on-Cogworks

- **Cogworks v0.13** will land the debug primitive (`cw:CreateDebug`); user will poke when ready. Then bump `.pkgmeta` external from v0.11 → v0.13 + sync vendored `Libs/Cogworks-1.0/` + refactor `/tally diag` onto `dbg:Diag({sections})` + add `dbg:Print` traces throughout.
- **[cogworks#23](https://github.com/gezmodean-wow/cogworks/issues/23)** — `CreateProgressBar` primitive. `UI/MultiProgressBar.lua` + `UI/ProgressBar.lua` are Tally-local pending this; lift when it lands.

## Handy facts

- Last acknowledged scribe player-facing conventions: `2026-04-30f` (re-fetch the doc when next writing player-facing copy)
- Cogworks pinned at `v0.11.0` in `.pkgmeta` (latest released is `v0.12.0`; `v0.13.0` will bring debug)
- Origin is current as of alpha4 tag
- Memory at `C:\Users\gezmo\.claude\projects\C--src-tally\memory\` has been updated with the strategic reframe + cogworks-v0.13 reference
