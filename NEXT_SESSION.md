# Tally — next session handoff

Picks up where the 2026-05-02 session left off after shipping `v0.1.0-alpha5`.

## What landed in alpha5

Three logical commits on `main`, tagged `v0.1.0-alpha5`:

- **Cogworks v0.13 adoption** — `.pkgmeta` external bumped v0.11.0 → v0.13.0 (vendored `Libs/Cogworks-1.0/` synced locally, gitignored). `/tally diag` now uses `cw:RegisterDebugInspector` (12 inspectors), `/tally diag copy` uses `cw:CreateCopyDialog` + `cw:DumpDebugState`, `/tally debug` opens `cw:CreateDebugConsole`. `ns.dbg` logger exposed for Phase A traces. `UI/MainFrame.lua` migrated to `cw:CreateThemedMainFrame` (sidebar hidden, tabs preserved). Slash dispatch migrated to `cw:RegisterSlashCommands`.
- **TLY-31 Phase A — native event capture** — `Sources/Native.lua` restructured into orchestrator + `Native.skipCounters` + `Native:RegisterBucket`. New buckets: `AHPosting.lua` (PostItem/PostCommodity/CancelAuction → ah-deposit / ah-cancel), `Vendor.lua` (MERCHANT_SHOW/CLOSED bag-delta + money-delta), `Repair.lua` (RepairAllItems money-delta), `Mail.lua` (TakeInboxMoney / SendMail). Existing AH-mail invoice capture moved unchanged into `AHInvoice.lua`.
- **Docs promotion** — CHANGELOG.md + RELEASES.md filled out under v0.1.0-alpha5 heading; this file refreshed.

## Blocking on tester input

Two open tickets are still waiting for `/tally diag` output (filed before alpha4; the diag improvements + native capture in alpha5 should give us much richer signal):

- **[TLY-24](https://github.com/gezmodean-wow/tally/issues/24)** — Toeknee's TSM-vs-Tally discrepancy. Bonus-ID fallback shipped in alpha4; need his diag to confirm the warband/per-char gold field-name issue.
- **[TLY-28](https://github.com/gezmodean-wow/tally/issues/28)** — Inventory tab shows empty after lag. Need diag + wizard-completion confirmation.

Once their diag arrives, fixes are likely one-line each in `Inventory/Ownership.lua` (gold field name) or wizard completion flow.

## Phase A is shipped but untested

The five new `Sources/Native/*.lua` bucket files were written without in-game testing — pure new ground hooking AH/merchant/repair/mail APIs. Expect first-run rough edges from testers. The `dbg:PrintDebug` traces in every bucket should make diagnosing easy: `/tally debug` → flip enabled → reproduce → look at the log tab.

Known V1 limitations to watch for:
- `AHPosting` emits `ah-deposit` on the hook, not on the actual `AUCTION_HOUSE_AUCTION_CREATED` confirmation event — a server-side post failure leaves an orphan row. Rare but possible.
- `Vendor` collapses an entire merchant session into one pair of rows per item; per-transaction granularity is sacrificed. Players who need it can run Journalator alongside.
- `Repair` only hooks `RepairAllItems`; per-item repair (clicking individual gear at the merchant) goes through a different code path and is out of scope for V1.
- `Mail` doesn't ledger item attachments — items in mail end up in bags which Syndicator captures separately.

## Other open issues, in priority order

- **[TLY-29](https://github.com/gezmodean-wow/tally/issues/29)** — capture-layer rigor. Skip counters shipped in alpha4 + extended in alpha5 (per-bucket prefixes); remaining work is the kind router for unknown kinds + structured per-source field map.
- **[TLY-30](https://github.com/gezmodean-wow/tally/issues/30)** — view-layer reconciliation. Depends on TLY-29 completion. Probably alpha6+.
- **[TLY-31](https://github.com/gezmodean-wow/tally/issues/31) Phase B** — demote sibling adapters to backfill-only by default, periodic ticker becomes off-by-default, setup wizard wording shifts to make the "Tally is the canonical record" stance explicit. Wait for tester confirmation that Phase A capture works before flipping the default.
- **[TLY-31](https://github.com/gezmodean-wow/tally/issues/31) Phase C** — `Ledger:Subscribe` API for sibling cogs to consume Tally's event stream + cross-cog migration plan for FlipQueue / Maxcraft.

## Stretch / latent work

- **Sidebar nav for `MainFrame`** — `cw:CreateThemedMainFrame` is built around sidebar nav; Tally currently hides the sidebar to preserve tab UX. Worth a UX discussion — sidebar might be the suite-standard pattern (FlipQueue / Tempo are likely candidates for adopting v0.13 in their next revs). User decision.
- **Cogworks `CreateProgressBar`** ([cogworks#23](https://github.com/gezmodean-wow/cogworks/issues/23)) — `UI/ProgressBar.lua` + `UI/MultiProgressBar.lua` are Tally-local pending this; lift when it lands.

## Handy facts

- Last acknowledged scribe player-facing conventions: `2026-04-30f` (re-fetch the doc when next writing player-facing copy)
- Cogworks pinned at `v0.13.0` in `.pkgmeta`
- Origin is current as of alpha5 tag
- Memory at `C:\Users\gezmo\.claude\projects\C--src-tally\memory\` — relevant entries: project_scope, feedback_no_push_without_approval, feedback_ui_before_ship, reference_cogworks_console, reference_flipqueue
