# Tally release notes

This file is the **player-facing** changelog. It's what shows up on CurseForge and Wago project pages. Plain language, organized by what players see and do — no file paths, no internal terminology, no commit references.

The engineering-detail companion lives in `CHANGELOG.md` (commit-readerese — file:line, internal jargon, full alpha-by-alpha breakdown). When working on Tally, update both: `CHANGELOG.md` for the engineering record, this file for the player surface.

---

## Unreleased

Restoring the things alpha18's structural rewrite deferred. The active-only baseline did its job — big rosters stopped hitting the saved-variables ceiling — but the cost was that sibling-source import had been ripped out and historical periods couldn't be reconstructed. alpha19 puts both back, this time as user-initiated flows you can pause, resume, and tune mid-flight. Net Worth's gold accounting also got more reliable for the case where one of your characters hasn't been touched in months.

### The import flow returns — pause-able, resume-able, tune-able

alpha18 stripped the per-login sibling-source import because it was the dominant logout/login tax on big rosters. alpha19 brings it back as an explicit flow with its own controls. The setup wizard gets two new steps when sibling addons (TSM Accounting, FlipQueue, Journalator) are detected: one to pick which sources and how much history (last 30 days through all history), one to pick the import speed (gentle / balanced / aggressive presets, or a custom budget per cycle).

While the import is in flight, a draggable control widget sits on screen showing per-source progress, current speed, and an estimated time remaining. You can pause it at any time, tweak the rows-per-cycle or seconds-between-cycles live, or stop it and resume later — even across `/reload` or relogging. The widget collapses to a small badge near the minimap if you want it out of the way; clicking the badge brings it back. The same controls are available via `/tally import` (`pause`, `resume`, `cancel`, `budget`, `delay`) for keyboard-driven setups.

The Finish button on the wizard kicks the import into the background and gets out of your way — Tally is live-capturing your auction-house, vendor, mail, and repair events the whole time, so nothing has to wait for the import to complete.

### Fill historical archives on demand

The Research, Lifecycle, and Compare tabs all get a new **Synthesise history** button. Each month your sibling addons cover but Tally doesn't have an archive for shows up here — the button's tooltip lists how many months are missing and roughly how many rows it would synthesise. Clicking it confirms, then writes one Tally archive per month in the background. Each completed period announces itself with a brief toast; the same archives then power Lifecycle's historical drill-downs, Research's per-item history, and Compare's full-history scope.

If you only ever want the current month's data and don't care about historical analysis, just leave the button alone — Tally won't touch sibling sources until you ask it to. If you fill more than the 60-archive pool can hold, Tally now quietly evicts the oldest archive to make room (rather than failing the save outright); evicted archives can always be re-synthesised on demand.

### Net Worth picks the freshest gold source

If you've been seeing one or more characters report 0 gold even though you know they had a balance last time you played, alpha19 fixes the most common path. Tally now considers up to three sources for each character's gold — its own live capture (added in alpha18), Syndicator's snapshot, and TSM Accounting's per-character gold log — and picks the one with the most recent timestamp. The character that hasn't logged in since you installed Syndicator+Tally now gets its gold from TSM if you have TSM Accounting installed, instead of reading 0.

`/tally diag gold` grows columns for each source it considers and a "winning source" column showing which one Net Worth is using per character, so you can confirm the freshest-source pick is doing the right thing on your account.

### Quieter, more organised output

Tally's chat output has been routed through a handful of focused channels. Brief acknowledgements ("snapshot taken", "import paused") now show up as toasts on the bottom-right of the screen instead of cluttering the chat frame. Multi-line diagnostic dumps like `/tally diag gold` open in a copy-paste dialog that's easier to grab from for issue reports. Engineering traces go to the in-game debug console (`/tally debug` — pending a Cogworks fix to land; not usable on this build). The few things that still print to chat — the on-demand net-worth readout, source-status notes — also mirror to the debug log automatically so you can always paste the last thing Tally told you regardless of where it appeared.

### Net Worth's Warband row split

The Warband row in Net Worth used to show one combined number for gold plus warband-bank items. It's now two rows — **Warband — gold** and **Warband — items** — each clickable to the warband inventory view. The old single number was the most common cause of "Tally's warband total looks too high" reports; this makes the breakdown obvious.

## v0.1.0-alpha18

The architecture rewrite, phase 1. **Your Tally ledger has been wiped as part of this upgrade — that's intentional, not a bug.** Settings, history snapshots, your pricing strategy, and your minimap button position are preserved; only the transaction ledger was reset. Sibling-source import (TSM, FlipQueue, Journalator) returns in the next alpha as a user-initiated, pausable flow.

### Why the wipe

For the last several alphas, very large accounts have been hitting a Lua data-storage limit that breaks Tally's saved-variables file outright. alpha14 worked around it with compression; alpha16 worked around it with per-month archive files. Both pushed the wall further out without removing it. alpha18 removes the wall structurally: the active ledger now lives in its own saved-variables file, and the main file holds nothing that grows with how much you trade. The wipe is the clean break between "old layout" and "new layout" — there's no in-place migration because the new layout is incompatible enough that we'd rather start fresh than risk corrupting anyone's data.

### What happens on first login

When you log into your first character on alpha18, the welcome wizard pops up explaining the reset. It's now a three-step flow — Welcome / Pricing Strategy / History — and **clicking Finish doesn't import anything**. From this login forward, Tally captures auction-house, vendor, mail, and repair events live as they happen. The Research, Lifecycle, and Compare tabs will be empty until enough activity accumulates.

This is a deliberate scope retreat. The old Tally tried to be the universal repository for your transaction history — re-importing every sibling addon's data on every character login. For people running through 20+ characters per session, that re-import work was the single biggest reason logins stayed slow. Going forward, Tally treats sibling addons as the authoritative store for their own data and pulls from them only when you ask for it.

### Help us pick the import speed for next alpha

Once alpha18 is loaded, run **`/tally diag sources`** and paste the result into [TLY-66](https://github.com/gezmodean-wow/tally/issues/66) on GitHub or the Discord thread. The command walks your TSM Accounting / FlipQueue / Journalator data once and reports how many rows each addon has, what time span it covers, and how the rows distribute across months. We'll use the readouts to size alpha19's import controller against real big-account distributions instead of guessing.

A heads-up: on accounts with very large TSM CSVs (tens of thousands of rows or more) the command takes several seconds and the client will appear to freeze briefly while it parses. That's expected — it's a one-time diagnostic, not a recurring background task.

### Net-worth gold accounting is more reliable

Tally now captures your character's gold directly from WoW at login and whenever your wallet changes, and your warband-bank gold whenever you open the account banker. Net Worth prefers these captured values over the Syndicator snapshot it was relying on before, so characters that occasionally dropped out of the per-character rollup should stop disappearing.

If you were affected by the gold-accounting issue tracked in [TLY-68](https://github.com/gezmodean-wow/tally/issues/68), you can check whether Tally's own capture is in play for each character via `/tally diag gold`. The `rollup` column shows the value Net Worth is actually using; characters where Tally's capture is fresher than Syndicator's show up there directly.

## v0.1.0-alpha17

A focused diagnostic alpha. Toeknee reported on alpha16 that Tally's net-worth view was showing different gold totals than his actual characters and warbank — 29M shown for warbank vs 37M actual, 179M shown for characters vs 108M actual. Two separate things look likely (the Warband panel row combining gold and warband-item value into one figure, plus one or more characters dropping out of the per-character rollup), but we need data from a real big-roster account to tell which is biting and on which characters.

This release ships a new command — **`/tally diag gold`** — that lists every character on your account with its Syndicator-reported gold next to the value Tally is summing, plus four flags pointing at the most likely silent-undercount paths. Run it, click the **Copy** button on the dialog that pops, and paste the result into [TLY-68](https://github.com/gezmodean-wow/tally/issues/68) on GitHub or the Discord thread mirroring it.

The same gold breakdown also shows up under the new **Gold** section of `/tally diag` for anyone running the regular diagnostic dump.

The fix itself follows in the next planned alpha once we have the data to confirm which path is dropping gold.

## v0.1.0-alpha16

The big structural overhaul to how Tally stores its ledger. Players with very large transaction histories — hundreds of thousands of rows accumulated across years of trading — were hitting freezes every time they switched tabs in Tally's main window, and the multi-second logout delays kept getting worse as histories grew. This release fixes both for good. Day-to-day Tally feels snappy regardless of how much history you've accumulated, and the deep-dive views still get the full picture when you ask for them.

### Tally is fast on huge histories now

Before this release, every time you opened the Ledger tab, Settings, or switched the Compare source dropdown, Tally re-walked your entire history from scratch — a few hundred thousand rows of clustered comparison happening in pure Lua, every click. On big accounts that ran multiple seconds of UI freeze; on the largest tester accounts the client locked up entirely.

The storage model is now split. Only the recent active window stays loaded at all times — at most around 25,000 rows or 60 days, whichever is smaller. Older months sit on disk in their own per-month archive files that nothing touches unless you specifically ask for full-history scope. The per-tab clustered scan that was the freeze cause now runs against a small, predictable working set. Tab switches feel instant. Logout-time saves only re-write the active blob, so they stay fast as your archives accumulate.

### How the migration works

If you've been running alpha14 or alpha15, your first login on this build kicks off a one-time migration in the background. You'll see a chat line:

```
Tally: Loading legacy ledger blob (chunked async deserialise).
```

The legacy data takes a couple of minutes to load on the biggest tester accounts (hundreds of thousands of rows from years of TSM/Journalator/FlipQueue history). **Critically, this happens without freezing the game.** Tally chunks the work across timer ticks so the input thread stays responsive — you can move your character, click around, and chat throughout. Frame rate dips to roughly 30 fps during the load on slower hardware, but nothing locks up.

Once the load finishes, Tally routes your data into the new tiered shape (current month rows go to active, older months go to archives). On a 200,000-row legacy ledger this typically takes ~5 seconds for routing and another ~1 second to write all the archives — substantially faster than alpha14/15 logouts on the same data. You'll see:

```
Tally: migration complete — 4,334 active rows, 47 archives, 195,666 archived rows. The new shape saves on logout.
```

If you log out before the migration completes, no problem — the original data stays on disk untouched, and the migration restarts cleanly on next login.

### Sealing keeps the active window manageable

If your active set ever exceeds the soft cap (25,000 rows or 60 days old), Tally surfaces a banner at the top of the main window: **"Sealing recommended: N rows older than ... waiting to archive."** Click it to seal — Tally moves the older rows into a monthly archive on disk and shrinks the active set back down. There's also a manual command (`/tally seal`) and a **Seal old data into archives** button under Settings → Maintenance for power users who want to control the timing.

The seal operation is chunked the same way the migration is, so it never freezes the client. A confirmation dialog appears before any cut larger than 5,000 rows so you don't accidentally archive your recent activity.

### Compare gains an "Include archives" opt-in

The Compare tab (Source A vs Source B side-by-side diff) now defaults to comparing only the active 60-day window. That keeps the tab snappy on big accounts even when picking sources that previously caused freezes. A new **Include archives** checkbox flips Compare into full-history mode — every monthly archive loads and the whole ledger gets compared. The summary line shows the current scope so you always know what window you're looking at.

The default-active behaviour also flows into the rest of the UI — Ledger, Settings, Inventory, Net Worth, and the Lifecycle drill-down all read from the active set unless you specifically ask for wider scope. (Lifecycle and the Research panel will gain their own opt-in archive loads in a follow-up release.)

### Logouts stay fast as archives accumulate

After the initial migration, archives are write-once. Subsequent logouts only re-write the small active blob — the dozens of monthly archive files Tally created during migration stay clean on disk and aren't touched at logout time. The first logout after migration does cost a few extra seconds because the operating system writes those new archive files for the first time, but every logout after that returns to the fast path.

### How to verify it's working

Run `/tally diag` and look for the **Storage** section. The new layout reports:

```
Storage: libs=yes loaded=yes dirty=no schema=v1
  Active: 4,334 rows, 142,243 bytes
    saved 2026-05-08 18:01:50  (serialise 138ms + compress 238ms; serialised 598018 bytes)
  Archives: 47 archives, 195,666 rows (slot-resident, raw)
    Slots: 47 / 60 allocated
  Total rows: 200,000 (active + archives)
```

The headline numbers to watch:
- **Active rows** should be in the low thousands once migration completes — current month plus a bit of carry-over.
- **serialise / compress times** on the active save should be tens to a few hundred milliseconds, not multiple seconds. That's the per-logout cost, now bounded by the active set's size cap.
- **Archive count** scales with how many months of history you have. Each archive is its own file on disk — small relative to the total.

A future release will reduce the in-memory footprint of archives (currently they stay fully resident as raw tables; a TSM-style lazy-parsed string format is queued for that work). For now, big accounts will see Tally's memory footprint roughly proportional to their ledger size.

## v0.1.0-alpha15

Quick perf fix on top of alpha14.

### Logout is fast again

After alpha14 enabled compressed-blob storage, players with very large transaction histories (tens of thousands of ledger rows) saw a multi-second freeze when logging out — Tally was doing all the compression work right at logout time, which blocked the UI before WoW could finish saving. This release switches to a faster compression setting that's roughly 5-10x quicker with only a small impact on file size. Logging out should feel snappy again.

### How to verify

Run `/tally diag` and look at the Storage section. The `blob last saved` line now shows the actual time spent serialising and compressing in milliseconds:

```
Storage: libs=yes loaded=yes dirty=no  mem=98000 entries  blob=350000 bytes (98000 entries)
  blob last saved: 2026-05-05 21:00:00  (serialise 1200ms + compress 200ms; serialised 5200000 bytes)
```

If your `compress` time on the next logout / login cycle is comfortably under a second, the fix is doing its job. Pre-fix on alpha14, the same compress step was taking ~3-5 seconds for that size of ledger.

## v0.1.0-alpha14

The structural fix for the saved-variables-too-large problem that was wiping testers' Tally state every session.

### Tally's database now stays small enough to actually load

The alpha13 popup mitigation only addressed the symptom — the underlying problem was that on accounts with very large transaction histories, Tally's saved-variables file gets too big for WoW to load on startup, and Tally was silently re-creating an empty database every session. That meant your ledger reset to zero every login, the welcome popup re-fired on every never-acknowledged alt, and the Native event-capture stayed disabled because the setup-completed flag never persisted.

This release moves Tally's ledger to a compressed storage format. The new format stores hundreds of thousands of transactions in a fraction of the space a raw table takes, so the file loads cleanly even on long-running heavy-trader accounts. From the player side: nothing changes about what Tally tracks or how it works — your ledger, pricing history, setup state, and net-worth widget all just *stay* across sessions like they should.

### What affected players need to do

If you've been hit by the popup-keeps-firing / ledger-keeps-empty problem (you'll know because Tally always feels like a fresh install), your old saved-variables file is still on disk and still too big to load. Recovery is one logout cycle:

1. Update to alpha14, log into any character.
2. Tally will look fresh-empty. That's expected — the old file is unreadable.
3. **Log out fully** (back to character select, or quit the game). This is the important step: it lets WoW write a *new* small saved-variables file to replace the old broken one.
4. Log back in. Tally now loads cleanly.
5. Run `/tally setup` and walk through the wizard. The backfill from your sibling addons (TSM, FlipQueue, Journalator) repopulates your ledger.
6. Log out and back in once more to confirm everything persists.

From this point on, Tally's storage stays compressed and your data sticks across sessions.

### How to verify it's working

Run `/tally diag` and look for the new **Storage** section. It shows:
- whether the compression libraries loaded (`libs=yes`)
- how many entries are in working memory
- how many bytes the on-disk blob is and how many entries it contains
- when it was last saved
- a warning marker if any legacy uncompressed data is still on disk (mid-migration state — should clear after one logout cycle)

For any tester comparing pre/post: the blob byte count should be a fraction of what your raw saved-variables file size used to be.

## v0.1.0-alpha13

A tester-feedback hotfix bundle picking up two persistent reports plus the matching root-cause investigation that came out of them.

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
