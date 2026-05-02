# Tally release notes

This file is the **player-facing** changelog. It's what shows up on CurseForge and Wago project pages. Plain language, organized by what players see and do — no file paths, no internal terminology, no commit references.

The engineering-detail companion lives in `CHANGELOG.md` (commit-readerese — file:line, internal jargon, full alpha-by-alpha breakdown). When working on Tally, update both: `CHANGELOG.md` for the engineering record, this file for the player surface.

---

## Unreleased

_Notes for the next tagged release will be distilled here. Pull from `CHANGELOG.md` and any closed issues' `## Player summary` sections, then organize into themed prose for players._

## v0.1.0-alpha3

A big alpha aimed at making Tally usable from the very first login — and at giving testers (especially the AH superusers with 700M+ gold and tens of thousands of transactions) the tools to see what Tally is doing and where its numbers come from.

### First-time setup wizard

When you install Tally for the first time, a six-step wizard now walks you through setup:

- Welcome and a quick explainer of Tally's "augment, not replace" stance toward TSM, FlipQueue, and Journalator.
- A live source-detection screen showing what data Tally found on your account and how big it is, with a checkbox per source so you can opt out of any of them.
- A concept primer with three live cards — Net Worth (saleable), Owned Worth (everything), and Warband — showing your real numbers, not abstract definitions.
- A pricing-strategy picker that values your bag four different ways side-by-side so you can pick the one that matches how you actually think about your wealth (and see why Tally and TSM might disagree on a headline number).
- A history-cadence configuration step.
- A backfill kickoff with three pace presets — Gentle, Balanced, and Aggressive — so you can choose between "I want to keep playing while it imports" and "I'll go AFK while it grinds."

While the import runs, a small panel docked bottom-right of your screen shows one progress bar per source so you can see exactly what's being imported and how far along each one is. Sources you opted out of, or sources that aren't installed, show as skipped instead of leaving you wondering.

The wizard re-opens any time via Settings → Re-run setup wizard, or `/tally setup`.

### Nothing imports until you're ready

Tally now imports nothing — from any source — until you finish the wizard. Mailbox events, the periodic background re-import, and the deferred login backfill all wait for the wizard to complete. Until then, the minimap icon clearly says "setup required" instead of pretending to show a (mostly-empty) net worth, and clicking it launches the wizard.

If you reset your data with `/tally reset confirm`, you go back to that pre-setup state — the wizard reopens with fresh choices and nothing flows in until you finish it again.

### Inventory drill-down

A new Inventory tab answers "what actually makes up my wealth?" Every owned item is listed across every character (and Warband), one row each, with sortable columns for character, location, quantity, unit value, total value, and percent of net worth. Filter by a single character or view everything together; toggle Saleable vs Owned to see how bound items shift the picture.

The Net Worth view's per-character section now shows a quick gold-vs-items split and percent of total under each character's name, and clicking any character drills straight into the Inventory tab pre-filtered to that character — so when one alt holds most of your wealth, you can immediately see what that alt is sitting on.

### Item lifecycle view

A new Lifecycle tab gives every item its own deep-dive. The view treats each AH listing as a "cohort" with a beginning (the deposit), middle (sale, expire, or cancel), and end (the realized net), then shows you:

- How many times you've posted that item.
- How many sold versus how many expired or were cancelled.
- Total revenue, fees, and deposit forfeits.
- Average time to sell.
- A pricing trend across your postings — improving, declining, or flat.

Cost basis (FIFO or weighted-average — toggleable) attributes the right purchase costs to each sale so the net-realized number reflects actual profit, not just gross revenue. Click any cohort row for the full detail: paired sale rows, fee breakdown, and the linked transactions. Reachable from the Lifecycle tab directly, from the Research panel's "View lifecycle →" button, or via `/tally lifecycle <item>`.

### Multi-source comparison view

If your Tally numbers don't match what TSM or another addon is showing, the new Compare tab helps figure out why. Pick any two registered sources (Tally Native, TSM, FlipQueue, Journalator, etc.), and Tally lines their rows up side-by-side, highlighting matches as strict, loose, or fuzzy and flagging rows that exist in only one of the two. A summary card at the top tells you at a glance how many rows each side has and the gross-copper delta, and an Export-to-chat button copies a paste-ready debug block of the top divergent rows for filing into a bug report.

The Compare tab is off by default — flip "Show ledger comparison tab" in Settings to enable it, or just type `/tally compare`.

### Journalator support

Tally now reads from Journalator's monthly archives across sixteen kinds of activity — not just AH sales and purchases, but vendor sells, repairs, taxis, trainer costs, quest gold, mission rewards, loot containers, trades, mail, trading post spending, and crafting orders. AH posting deposits flow through too, which is what unlocks the lifecycle view's cohort tracking. Tally never modifies sibling-addon data; it just reads.

### Quality-of-life fixes

- Settings page is now scrollable so it doesn't overflow the main frame.
- Concept-primer cards auto-size to fit their text so the Warband description doesn't clip.
- Net Worth's per-character section is more readable: bigger row height, full-width name column, and the chart resizes proportionally so the character panel always has room for full character-realm names.
- Pricing-strategy step uses a fallback character that renders cleanly across all locales (one tester saw the original arrow as a missing-glyph box).

### New slash commands

- `/tally setup` — re-run the first-time wizard
- `/tally inventory [character]` — open the Inventory drill-down (optionally pre-filtered)
- `/tally lifecycle <item>` — open the Lifecycle view for an item
- `/tally compare` — open the multi-source comparison

## v0.1.0-alpha2

Performance overhaul aimed at users with very large addon datasets — those running TSM with tens of thousands of accounting rows or FlipQueue with multi-megabyte logs.

- Background imports no longer fire on every bag-slot change, every auction posted, or every piece of mail received. Sibling-source backfill now runs once at login (deferred so first-zone-load isn't fighting it), every five minutes after that, and on demand from Settings.
- Inventory rebuilds are scoped and debounced — opening a single mail no longer triggers four full-account rescans.
- Saved-variables history defaults tightened (90-day retention, 7-day rollup window, 12-hour snapshot interval) so the file size stays bounded for heavy users. Existing users on the old defaults are migrated automatically.
- Warbound items now belong to the Warband, not whichever character is holding them — a "Warbound until equipped" sword in your alt's bags is the warband's, not the alt's.
- Net Worth, Research, and Settings panels redesigned with the suite-shared chrome and switchable views.
- Multi-source ledger lands as a foundation: Tally writes to its own ledger from native AH-mail events, and reads from TSM and FlipQueue alongside it.
- Per-realm profit-and-loss in the Research view, plus richer per-item context including Auctionator shopping list memberships and FlipQueue todo references.

## v0.1.0-alpha1

Initial alpha. Net worth across all characters, an LDB minimap launcher with a live total, per-item research with multi-source pricing, and a pricing-history substrate ready for replay.
