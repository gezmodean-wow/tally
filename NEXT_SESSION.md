# Tally — next session handoff

Picks up after the 2026-05-03 session. Last shipped: `v0.1.0-alpha7` (TLY-39 hotfix on top of alpha6 — Cogworks v0.13.0 → v0.13.1 to pick up COG-26 ESC handler fix).

## State

- Working tree clean. Alpha7 commits pushed (`9ab59b2` fix, `9357a38` docs); tag `v0.1.0-alpha7` pushed; release CI run 25295398018 succeeded; player-facing TLY-39 update posted.
- Cogworks pinned at `v0.13.1` in `.pkgmeta`; vendored `Libs/Cogworks-1.0/` synced (gitignored).
- Memory at `C:\Users\gezmo\.claude\projects\C--src-tally\memory\` updated with alpha-cadence preference (`feedback_alpha_cadence.md`).

## The big change for next session: compressed alpha cadence

Per user direction (saved as `feedback_alpha_cadence.md`): **alphas ship full critical-path bundles, not incremental planned work.** Subsequent alphas exist only to fix tester-reported problems. Phase the development internally across sessions / commits, but only `git tag` when the bundle is complete.

Practical consequence: do NOT tag intermediate alphas as you finish each phase below. Commit each phase to `main`, but hold the tag until the whole alpha8 bundle (Phase 1 → 4) is done.

## Alpha8 scope: authoritative ledger (full critical-path)

Reflected on [TLY-30 comment](https://github.com/gezmodean-wow/tally/issues/30#issuecomment-4365424684). Bundle ships:

1. **[TLY-36](https://github.com/gezmodean-wow/tally/issues/36)** — Resolve itemID at adapter source (Native AHInvoice + FlipQueue)
2. **[TLY-37](https://github.com/gezmodean-wow/tally/issues/37)** — Compare matcher: itemName fallback when itemID is nil
3. **[TLY-38](https://github.com/gezmodean-wow/tally/issues/38)** — Compare export: kind + source columns, dual-side sample, optional noise filter
4. **[TLY-29](https://github.com/gezmodean-wow/tally/issues/29)** — Capture-layer rigor: `Ledger.Schema`, `Ledger.Kinds.Unknown` + kind router, structured per-source field map
5. **[TLY-30](https://github.com/gezmodean-wow/tally/issues/30)** — `Ledger.Authority` priority map, `Ledger:Reconcile(filter)` API, consumer migrations (Lifecycle, Research, Ledger page)
6. **[TLY-31 Phase B](https://github.com/gezmodean-wow/tally/issues/31)** — Demote sibling adapters to backfill-only by default; periodic ticker off by default; setup wizard wording shifts

Estimated scope: 1500–2500 LOC across adapters, schema, Reconcile API, consumer migrations, wizard config.

## Phase 1: data-quality + diagnostic surface (TLY-36 + 37 + 38)

Smallest slice; lands cleanly in one session. Independent of the bigger TLY-29/30 work but a precondition for it.

**TLY-36 — itemID resolution at adapter source**
- `Sources/Native/AHInvoice.lua`: resolve itemID from itemName via `GetItemInfoInstant(itemName)` for sale / purchase / ah-fee rows. Cache the lookup per session in a local map (`itemNameCache[name] = itemID`) so the same item across many invoices hits cache. Add skip counter `invoice_no_item_id` for rows where the lookup returns nil (some old items legitimately won't resolve).
- `Sources/FlipQueue.lua`: in `mapEntry`, if `itemIDFromKey(itemKey)` returns nil, fall back to `entry.itemID` directly when present, then to parsing `entry.itemLink` via `GetItemInfoInstant`. Add skip counter `bad_item_key`.
- Both adapters: increment new skip counters in the existing `skipCounters` table so `/tally diag` SkipCounters inspector picks them up automatically.

**TLY-37 — Compare matcher itemName fallback**
- `Ledger.lua` near `indexByCharItem` (~497) and `findMatch` (~514): build a secondary index keyed by `(charKey, itemName_lowercased)`. Only populated when `meta.name` (or `meta.itemName`) is present and non-empty.
- Add a fourth match tier `name` between `loose` and `fuzzy`. Fires when an A-side row has `itemID == nil` but a non-empty name and the B-side has a row with the same name within `LOOSE_WINDOW`.
- Update `Compare` summary stats with `name` field; update `TIER_COLOR` map in `UI/CompareLedgersPage.lua` (amber, between loose's gold and fuzzy's orange).

**TLY-38 — Compare export improvements**
- `UI/CompareLedgersPage.lua` `exportBtn` handler: walk `pairs_out` twice — once for top-5 A-only, once for top-5 B-only. Print headers between sections. Format each row with `source` and `kind` columns: `[A-only] 03/12 00:03 | flipqueue | ah-cancel | Flipron-Maelstrom | item:? | 0c`.
- After the per-row sample, print bucket-count summaries: `A-only by kind: ah-cancel=180, ah-expire=104, sale=27, ...` and `... by source: flipqueue=290, tally-native=41`. Same for B-only.
- Add a checkbox above the export button: `[ ] Hide expire/cancel rows in export`. When checked, skip rows where `copper == 0`. Default off.

## Phase 2: capture-layer rigor (TLY-29)

Touches every adapter — schedule after Phase 1 lands so itemID resolution stabilizes first.

**`Ledger.lua` additions:**
- `Ledger.Schema = { sale = { canonical = {...}, sourceFields = { tsm = {...}, native = {...}, ... } }, ... }`. Per (kind, source), declare canonical fields + source-specific extras.
- `Ledger.Kinds.Unknown = "unknown"`. `KindSign("unknown")` returns 0 (neutral). Adapters route any source-kind they don't recognize to `Unknown` with the original payload preserved in `meta.sourceKind`.

**Adapter refactor (touches all of them — Native/*, FlipQueue, TSM, Journalator):**
- Each adapter declares which source-kinds it knows. Unknown source-kinds → `Ledger.Kinds.Unknown` instead of silent drop / wrong-kind fallback (TSM currently falls back to `sale` which is wrong if the source was actually "Trade").
- Migrate the free-form `meta` table population to declare canonical vs source-specific fields per the new Schema. Existing `meta` consumers in Lifecycle / Research keep working — Schema is additive structure, not a replacement.
- Keep skip counters (already in place from earlier work); they're the loss-accounting half of TLY-29.

## Phase 3: authoritative ledger via Reconcile (TLY-30)

The big workstream. Probably one full session minimum.

**`Ledger.lua` additions:**
- `Ledger.Authority = { sale = { atTime = { "native", "journalator", "tsm" }, copper = { "tsm", "native", "journalator" }, ... }, ... }`. Per (kind, field), declare source priority.
- `Ledger:Reconcile(filter) -> records[]` — groups raw query results by `(charKey, itemID, count_window, atTime_window)` (same heuristic Compare uses). For each grouped event, build one record where each field comes from the highest-priority source that has it, with `provenance = { atTime = "native", copper = "tsm", ... }` mapping field → source.

**Consumer migrations:**
- `Research/Lifecycle.lua`: switch sale-matching from `Ledger:Query` to `Ledger:Reconcile`. Users with Journalator no longer see duplicate cohorts when Native + Journalator both observed the same posting.
- `Research/Aggregator.lua`: `Research:GetRecord` switches sales/purchases from raw `Query` to `Reconcile` so per-item P&L stops over-counting.
- `UI/LedgerPage.lua`: add a `Reconciled / Raw` toggle. Default to Reconciled. Raw mode preserved for power-user debugging.
- `NetWorth/Calculator.lua`: no change — reads Inventory + Pricing, not the ledger.

## Phase 4: demote sibling adapters (TLY-31 Phase B)

Smaller; can land same session as Phase 3 if time permits.

- Sibling-adapter periodic ticker default flips: `TallyDB.sourcePolicy.tickerEnabled = false` (was effectively-true via 5-min `C_Timer.NewTicker` in `Core.lua` PLAYER_LOGIN). Native source stays event-driven (no change).
- One-shot at PLAYER_LOGIN still fires for sibling adapters (so backfill works without user action), but no recurring tick.
- `UI/SetupWizard.lua` source-detection step wording: relabel sibling sources as "Backfill from <source>" rather than "Import from <source>". Helps users understand the new role.
- `UI/SettingsPage.lua` DATA SOURCES section: add a label clarifying that sibling-source imports are now manual / one-shot, with "Import now" buttons per source unchanged.

## Tester signals still live (independent of alpha8 bundle)

- **[TLY-24](https://github.com/gezmodean-wow/tally/issues/24)** — Toeknee's TSM-vs-Tally discrepancy. `/tally diag` from alpha6 needed to confirm warband/per-char gold field name. Fix likely one-line in `Inventory/Ownership.lua`.
- **[TLY-28](https://github.com/gezmodean-wow/tally/issues/28)** — Inventory tab empty. Need diag + wizard-completion confirmation.
- **[TLY-33](https://github.com/gezmodean-wow/tally/issues/33)** — Closed but waiting for tester re-test confirmation that the alpha6 fix resolved the integer overflow.
- **[TLY-35](https://github.com/gezmodean-wow/tally/issues/35)** — Welcome popup per-toon question (filed by scribe; not yet triaged).

If any of these get tester replies during the alpha8 work cycle, evaluate whether to fold into alpha8 or split as alpha8-hotfix tags. Per cadence preference, prefer folding when feasible.

## Waiting on Cogworks

- **[cogworks#23](https://github.com/gezmodean-wow/cogworks/issues/23)** — `CreateProgressBar` primitive. `UI/ProgressBar.lua` + `UI/MultiProgressBar.lua` are Tally-local pending this; lift when it lands.

## Handy facts

- Last acknowledged scribe player-facing conventions: `2026-04-30f` (re-fetch when next writing player-facing copy)
- Cogworks pinned at `v0.13.1` in `.pkgmeta`
- Origin current as of `9357a38` (alpha7 docs commit)
- Slash commands now use `cw:RegisterSlashCommands` — auto-help renders from per-command `{ name, run, help, args, aliases }`. Add new commands as table entries in `Core.lua`'s `RegisterSlashCommands` block, not via separate `SLASH_*` globals.
- Debug toolkit: `ns.dbg:PrintDebug(...)` for trace logging; `/tally debug` toggles the live console; `/tally diag copy` opens the structured paste-friendly dump.
- Memory entries to read when starting: `feedback_alpha_cadence` (the new cadence rule), `feedback_no_push_without_approval` (push approval), `feedback_ui_before_ship` (UI-before-shipping principle), `project_scope` (what Tally is), `feedback_player_summary` (scribe doc URL).
