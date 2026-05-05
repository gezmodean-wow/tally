# Tally release notes

This file is the **player-facing** changelog. It's what shows up on CurseForge and Wago project pages. Plain language, organized by what players see and do — no file paths, no internal terminology, no commit references.

The engineering-detail companion lives in `CHANGELOG.md` (commit-readerese — file:line, internal jargon, full alpha-by-alpha breakdown). When working on Tally, update both: `CHANGELOG.md` for the engineering record, this file for the player surface.

---

## Unreleased

### The welcome popup actually stays dismissed now

Two testers (thank you Toeknee and zpectre) confirmed across multiple alphas that the welcome popup kept firing on every alt no matter how many times they hit Cancel. Turned out the gate logic was correct — the issue was that on accounts with very large Tally databases, the saved-variables file fails to load entirely, which wipes the "I dismissed this" flag every session. The popup was firing because Tally genuinely thought you were a fresh install each login.

Tally now also tracks "I've already dismissed this" per character in a separate, much smaller saved-variables file that doesn't hit the load failure. Either Cancel or Next on the wizard sets the flag, and from then on that character won't auto-popup again. New characters still see the popup once each — that's a minor change from "once per account, ever" — but it's a reliable per-character one-shot instead of an unreliable account-wide one.

A separate longer-term fix is needed for the underlying database-too-large problem — for affected testers, the ledger and setup state still won't persist between sessions. That work is queued under [TLY-32](https://github.com/gezmodean-wow/tally/issues/32).

### Tally totals stop under-counting when you use TSM (or other AH addons) alongside

If you've had Tally consistently showing lower sales / item totals than TSM — especially as a high-volume trader posting many of the same item — that's been a structural bug in how Tally combined overlapping records from different addons. Two TSM rows for the same item within five minutes were getting treated as one event, so the second sale's value silently dropped.

After this fix, each TSM row counts as its own event unless a different source (Native, Journalator, FlipQueue) also observed it. Vendor-sell flurries, back-to-back postings, and same-item purchases close together all start counting correctly. Your sales counts and items value will move noticeably closer to what TSM shows. They won't match exactly — TSM has historical rows from before Tally was tracking, and a few earlier classification quirks may leave residual differences in stale entries — but the structural under-count is gone.

If you want to see the impact directly, run `/tally diag divergence` before and after — the "field disagreements" count should drop substantially.

## v0.1.0-alpha12

Single-issue hotfix on top of alpha11. Picks up a critical Cogworks library fix.

### Knowledge tomes and confirmation-popup items right-click again

If you've had bag items quietly refuse to be right-clicked while Tally was loaded — knowledge tomes, profession consumables, or anything that pops a *use this?* confirmation — that was a Cogworks library bug that's now fixed. The confirmation popup will appear and the item will use normally on confirm. No settings change needed; the bundled library update does it.

Items without a confirmation popup (gear, tradegoods) were never affected, which is why the bug took a while to surface.

## v0.1.0-alpha11

Quick follow-up on alpha10's first-run popup fix.

### The welcome popup is now one-and-done

Testers on alpha10 still saw the popup on every alt. Turned out the *Don't show this on login again* checkbox we added was easy to miss — so people were just hitting Cancel, and Cancel-without-the-checkbox by spec re-fired next login.

The simpler thing was the right thing. The checkbox is gone. Now the welcome popup gives you two choices:

- **Click Next** to start setup. If you walk away mid-wizard, that's fine — the popup still won't come back.
- **Click Cancel** to skip. Same outcome — popup doesn't come back.

You can re-open the wizard any time from Settings → Re-run setup wizard, or run `/tally setup`. Either way, you only see the auto-popup once per account, ever.

## v0.1.0-alpha10

The big one — closes the data-quality story Tally has been building toward since alpha5. Numbers stop double-counting when you have multiple AH addons installed, an unrecognized transaction type now surfaces in the UI instead of silently disappearing, and a new diagnostic catches anything Tally missed while it wasn't running.

### First-run popup actually goes away when you tell it to

Before alpha10, the welcome popup re-fired on every alt — and on the same character multiple times — even after you walked through the wizard. Common path: you opened the wizard, clicked Cancel partway through, and the popup kept appearing on every login.

Alpha10 fixed the underlying bug, and alpha11 simplifies the UX further (see above). The minimap icon also calms down once setup is skipped — the gold *setup required* tooltip becomes a quiet gray *setup skipped* with a one-line note about how to re-run from Settings.

### Reconciled ledger view — one row per real event

If you have TSM, FlipQueue, or Journalator installed alongside Tally, you've probably noticed that the same sale / posting / cancel can show up two or three times in Tally because each addon observed the same event. That's been making Lifecycle cohort counts look inflated and per-item P&L look exaggerated.

Alpha10 adds a *reconciled* view that collapses those duplicates into one record per real event, picking the best value for each field from whichever source captured it most accurately. The Ledger tab defaults to this view; a *Raw* toggle switches back to the per-source rows for power users who want to see who saw what. The Source column annotates merged rows ("native+2") so you can see at a glance when multiple addons agreed on something.

Behind the scenes, Lifecycle and per-item Research now read the reconciled view too — your posting counts and P&L numbers will look more honest after this update.

### "Unknown" filter for transactions Tally couldn't classify

When TSM, FlipQueue, or Journalator emits a transaction with a type Tally doesn't recognize (a TSM "Trade" row, a future FlipQueue auction status, etc.), Tally used to either silently drop it or — worse — guess wrong and file it as a sale. Now those transactions land in a new *Unknown* bucket, preserving the original type tag so we can see what's actually happening. The Ledger tab gets an *Unknown* filter chip after *Other* so testers can isolate them in one click.

If you don't have any of those rows, the chip stays empty and Tally classifies everything correctly — which is the everyday case.

### Sibling-addon imports are explicitly backfill, not periodic

Before alpha10, Tally was re-running TSM / FlipQueue / Journalator imports every 5 minutes whether you wanted it to or not. With native capture (alpha5+) covering live events, that 5-minute loop was redundant — Tally already saw what was happening as it happened. The recurring re-import is gone.

Sibling addons are now framed in the UI as **backfill sources**: imported once during the first-run wizard to recover history Tally couldn't have observed, and re-importable manually from Settings → Import now per source whenever you want to top up. The wizard wording, the Backfill step note, and the Settings header all say *backfill* now to set the right expectation. The Finish button reads *Finish & Backfill*. None of the buttons changed function — only the framing.

### Divergence diagnostic — does Tally have everything?

`/tally diag divergence` is a new slash subcommand that opens a paste-friendly window with three buckets:

- **Real gaps** — events your sibling addons captured during a session when Tally was actually loaded. These are the bugs we want to fix.
- **Expected gaps** — events your sibling addons captured during a session Tally wasn't loaded. This is what backfill is for, no action needed.
- **Field disagreements** — events all your addons captured but disagreed on the price / time / count. The reconciled view picks the most reliable source for each field; this list shows where the picks were happening.

The header tells you how much of the last week Tally was actually observing, and per-source contribution counts so you can see at a glance ("TSM contributed 4327 rows, Tally's native source 891"). The auto-divergence-check fires once a minute after login and quietly emits a one-line chat hint only if there are *real* gaps to inspect — silent otherwise so it stays out of the way.

### Diagnostic dumps are copy-pasteable by default

Per tester feedback that pasting from chat scrollback is painful, `/tally diag` now opens directly into the structured copy-dialog. If you specifically want the chat output, use `/tally diag chat`. The previous `/tally diag copy` form keeps working as an alias.

## v0.1.0-alpha8

A data-quality + UI polish alpha. Tally's matching against TSM / FlipQueue / Journalator gets sharper, the Compare and Ledger views both gain a copy-friendly export dialog, and a stack of tester-feedback fixes lands on top of the alpha7 surface.

### More accurate item identification

When Tally captures an AH mailbox invoice it now resolves the item's ID immediately instead of leaving it blank, and FlipQueue rows whose item key was malformed or missing now fall back to the item link to recover the ID. Net effect: more of your historical AH activity shows up correctly in per-item Research, Lifecycle cohorts, and the Compare view — fewer rows attributed to "unknown item" because the source addon happened to drop the ID.

### Compare view smarter and faster

- A new "name" match tier connects rows that share a character + item name but lack an item ID on one side, sitting between the existing loose and fuzzy tiers. Useful for matching old native-capture rows against current TSM / FlipQueue data.
- Export-to-chat is now Export-to-dialog. The report opens in a copy-paste-friendly window instead of being dumped into the chat frame (which mangled long lines and was hard to select). The new format also gives a dual-side sample plus by-kind / by-source bucket counts so divergence reports are useful at a glance. New checkbox to hide expire/cancel rows from the export.
- The Compare tab no longer pre-selects sources on open or remembers your selections across tab switches. Re-entering the tab is instant; pick Source A and B fresh each time you want a comparison.

### Ledger tab gains export

Same copy-friendly dialog pattern, on the Ledger tab. Click Export to grab the currently-visible transactions (whichever filter chip you have on — All, Sales, Purchases, AH Activity, Other) into a paste-ready window. Useful for filing GitHub issues with concrete data, or pulling a subset into a spreadsheet for external analysis.

### Warband counts no longer climb forever

A bug caused Warbound items in your bags (heirlooms, achievement rewards, anything bound to the warband) to duplicate every time you moved an item or posted at the auction house — your "Master of Fishing" could climb to 4 or 5 within seconds of normal play. Fixed. The first login after this update triggers a one-time full inventory rescan to clear out any inflated counts already on disk; you don't need to do anything manually.

### Tab name no longer overlaps the leftmost tab

A small chrome regression where the active tab's name rendered as floating plaintext over the *Net Worth* tab on the left of the strip. Removed; the tab buttons themselves indicate which page is active.

### Behind the scenes

The release pipeline now runs a verification step before publishing — asserts the built zip has its embedded library directory populated, every `.lua` and `.xml` file referenced by the table-of-contents actually exists in the package, and the archive isn't trivially small. Catches the failure mode that produced the alpha6 "couldn't open Cogworks-1.0.xml" report before it can ship.

## v0.1.0-alpha7

Hotfix on top of alpha6.

### Game menu / logout / quit no longer locks up after opening Tally

A bug in the Cogworks library bundled with alpha6 caused the Escape key to silently stop working after you opened (or even just closed) Tally's main window. Pressing Escape would do nothing and the game menu, logout dialog, and quit dialog all became unreachable until you typed `/reload`. The fix updates the bundled Cogworks library to use Blizzard's standard close-on-Escape mechanism, which doesn't interfere with the game menu. No settings change needed — just install this update and the issue stops happening immediately.

## v0.1.0-alpha6

Hotfix on top of alpha5.

### High-value AH posts no longer error

A bug in alpha5's native auction-house capture caused Tally to error out whenever the value of a posted item exceeded about 214,748 gold. The fix raises the internal ceiling well above any plausible WoW copper amount, so the error should stop after you update. Posts that errored before don't get backfilled automatically — but the next time you post a similar item, it'll be captured normally. Same fix also patches a few related spots in the Journalator import path that had the same overflow shape latent.

## v0.1.0-alpha5

A meaningful pivot: Tally now records your activity natively instead of leaning on TSM, FlipQueue, or Journalator as the primary capture path. Plus a much better diagnostic story for testers.

### Tally now records your auction-house, vendor, repair, and mail activity directly

Until this alpha, Tally got most of its data by reading what TSM, FlipQueue, and Journalator had already captured. Now Tally watches WoW directly:

- **Auction posts and cancels.** Every time you post an item or cancel an auction, Tally records the deposit and the cancel immediately — no waiting for the next sibling-addon import to catch up.
- **Vendor visits.** Selling junk to a vendor, buying repair kits / pet food / vendor mats — both directions land in the ledger the moment you close the merchant window. Sales attribute the item's vendor sell-price; buys attribute the merchant's listed unit price.
- **Repairs.** Bulk repairs ("Repair All") are tracked with their actual cost — both player-paid and guild-bank-paid (the guild-paid ones are recorded as activity at zero cost so they show up in your history without inflating expenses).
- **Mail.** Sending or receiving money via mail (non-AH) gets ledgered. AH invoice mail is already captured separately and isn't double-counted.

What this means for you:

- If you have TSM / Journalator / FlipQueue installed, Tally still imports from them — your historical data is preserved. Going forward, Tally and the sibling addons are observing the same events independently; over time Tally becomes the canonical record and the sibling imports become useful only for backfilling history that pre-dates Tally's installation.
- If you DON'T have any sibling auction addon installed, Tally now actually works as a standalone ledger. Your AH and vendor activity flow in directly from gameplay.

### Live debug console

A new `/tally debug` command opens an in-game window showing what Tally is doing in real time: the events it sees, the rows it writes, the current state inspectors, action buttons. If you're helping test, this is the easiest way to give us a clear picture of what's happening on your client without having to round-trip more questions over Discord.

### `/tally diag copy` for cleaner bug reports

The existing `/tally diag` command still chat-prints the same dump for inline reading. The new `/tally diag copy` opens a structured dialog with the same data in copy-paste-friendly format — easier to drop cleanly into a GitHub issue.

### Main frame chrome rebuilt on the suite primitive

Tally's main window now uses Cogworks's shared chrome. No visible change in behavior; this just means the title bar, resize grip, ESC handler, and position memory live in one place across all the cogs.

**Heads up:** the way Tally remembers your window position changed, so on first login after this update the window will pop up centered. Drag it once and the new position will stick.

### Slash commands work the same; auto-help is now built-in

`/tally help` (and any unknown subcommand) renders the command list automatically from each command's definition. Same 14 subcommands as alpha4 with the same names and aliases — only the help-rendering plumbing changed.

## v0.1.0-alpha4

### More accurate item valuation

When TSM doesn't have market data for an exact item variant (typical for crafted gear, catalysts, and anything with bonus IDs attached), Tally now retries the lookup against the base item ID before falling through to vendor price. Previously these items showed up at vendor value — often 100x lower than reality — silently undercounting your net worth by potentially huge margins. If you've been seeing a gap between Tally's number and TSM's, this closes part of it.

### Diagnostic dump knows more

`/tally diag` now reports two extra things useful for tracking down accuracy mismatches:

- **Skipped-row counts per source.** If TSM had 50,000 sales rows and Tally only imported 49,953, the dump now tells you that 47 rows were skipped and groups them by reason (item missing, kind unrecognized, etc.). No more silent data loss; if something's getting dropped you can see it.
- **Raw Syndicator gold-field probe.** Tally prints whatever Syndicator actually returns for your current character's gold and your warband's gold under multiple likely field names. Useful when our gold totals disagree with what TSM or another addon shows — we can see immediately whether it's a Syndicator-side issue or something Tally is misreading.

### Diagnostic dump for bug reports

A new `/tally diag` command prints a structured snapshot of Tally's state to chat — addon versions, whether Syndicator sees your characters, what's in your rollup and ledger, sibling-addon detection, memory usage. If something looks wrong (your inventory is empty, your net worth doesn't match what you expect), paste the output into the GitHub issue and we can diagnose without rounds of "what version are you on, do you have TSM, etc."

### Main frame is resizable

Drag the corner grip at the bottom-right of Tally's main frame to resize. The new size persists across sessions. Tables and charts inside the frame re-layout live as you drag, so the Compare tab (and any other view with wide tables) is finally fully visible.

### Compare tab: pick "Tally Ledger" against a source

The comparison view has a new entry in both source dropdowns called **Tally Ledger (all)**, which represents everything currently in your ledger regardless of where it came from. By default the Compare tab now opens with Tally Ledger on the left and your first detected source on the right, so the immediate question becomes "is my ledger up to date with this source?" — exactly the comparison most testers were trying to make. The original two-real-sources comparison still works; just pick two non-Ledger entries from the dropdowns.

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
