# Tally — Personal Capital for World of Warcraft

**Tally is a portfolio dashboard for World of Warcraft.** It tracks the gold, items, tokens, and auctions you own across every character on every account, calculates your net worth, captures price and inventory history over time, and gives you a research view for any item you ask about.

Tally isn't here to replace the great tools you already use — it's built to augment them. [TSM](https://addons.wago.io/addons/tradeskillmaster) handles pricing data and posting rules. [FlipQueue](https://addons.wago.io/addons/flipqueue) handles cross-realm flipping. [Auctionator](https://addons.wago.io/addons/auctionator) handles shopping. Tally pulls them all into one dashboard where you can see what you own, what it's worth, how it's evolving, and where the gold is going.

<!-- SCREENSHOT: Main frame showing the net-worth-over-time chart -->
<!-- ![Tally main frame](https://i.imgur.com/PLACEHOLDER_HERO.png) -->

---

## Step 1: See What You're Worth

The foundation of any portfolio dashboard is knowing what you own. Tally rolls every tradeable item, every piece of gear, every active auction, every WoW Token, and every gold piece on every character into one number.

- **Cross-character net worth** — gold + items + tokens + AH-listed inventory, summed across every character on every account
- **Saleable vs owned-worth** — net worth defaults to *saleable only* (excludes soulbound), with owned-worth as a separate view that includes equipped gear, void storage, and bound items
- **Active AH auctions count toward net worth** — items currently listed are still being sold, so they're saleable by definition
- **Warband bank** — surfaced as its own bucket so you can see what's pooled vs. what's per-character
- **Per-character breakdown** — see which characters carry the most value, what's gold vs. items, and where to focus
- **TSM-backed valuations** — uses any TSM custom price expression you choose (`DBRegionMarketAvg` by default), with WoW Token live pricing and vendor-price fallback when TSM isn't installed

<!-- SCREENSHOT: /tally networth chat output showing per-character breakdown -->
<!-- ![Net worth breakdown](https://i.imgur.com/PLACEHOLDER_NETWORTH.png) -->

---

## Step 2: Watch It Evolve

Net worth is a *stock*. The interesting question is the *flow* — how is your portfolio changing over time, and where's the value going?

- **Net-worth-over-time chart** — visualize how total value is moving across the last 7 days, 30 days, 90 days, or all of recorded history
- **7d / 30d Δ in the LDB tooltip** — at-a-glance trend without opening the UI, color-coded by direction
- **Strategy-keyed price history** — every owned item's price is recorded under the active TSM strategy, so you can see how the market has moved on each item without losing data when you switch strategies
- **Per-character per-location inventory history** — track how holdings shift between bags, bank, AH, void, and across characters over time
- **Historical net-worth replay** — `/tally networth at -7d` reconstructs your total at any past time using the nearest-prior price + inventory snapshots
- **Configurable cadence and retention** — snapshots default to every 6 hours, kept for a year with a daily-rollup past 30 days. All four knobs are user-configurable from chat
- **No external service** — everything stays in your `SavedVariables`; no telemetry, no upload

<!-- SCREENSHOT: Net-worth-over-time chart with time-range buttons -->
<!-- ![History chart](https://i.imgur.com/PLACEHOLDER_HISTORY.png) -->

---

## Step 3: Drill Into Any Item

Per-item research that combines pricing across every TSM source, your sales history (when [FlipQueue](https://addons.wago.io/addons/flipqueue) is installed), where the item lives across your characters, and how its price and inventory have moved over time.

- **`/tally research <itemlink-or-id>`** — full record for any item, drillable from chat
- **Multi-source pricing snapshot** — DBMarket, DBRegionMarketAvg, DBRegionSaleAvg, DBHistorical, DBMinBuyout, vendor — all visible, not just the one your strategy chose
- **Saleable / bound / per-location ownership** — see exactly where your copies live: bags, bank, mail, equipped, void, auctions, warbank
- **Sales + auction history** — pulled read-only from FlipQueue's log when FlipQueue is installed; preserves FlipQueue's existing record shape
- **7d / 30d trend deltas** — for both price and inventory count, with per-character attribution when multiple characters moved
- **Bonus-ID aware** — bare item IDs aggregate across all variants; full item links match exactly

<!-- SCREENSHOT: /tally research output for a sample item -->
<!-- ![Item research](https://i.imgur.com/PLACEHOLDER_RESEARCH.png) -->

---

## Step 4: Plugs Into Your Toolkit

Tally is designed to enrich the tools you already run, not compete with them.

### [Syndicator](https://addons.wago.io/addons/syndicator) (required)

Tally reads inventory directly from Syndicator — no separate scanner, no duplicated overhead. Bags, bank, warband, mail, equipped, void, and active auctions all flow through Syndicator's cache and update live.

### [TradeSkillMaster](https://addons.wago.io/addons/tradeskillmaster) (recommended)

TSM provides the price data Tally values items against. Any TSM custom price expression works as your strategy. Without TSM, Tally falls back to vendor sell price as a floor.

### [FlipQueue](https://addons.wago.io/addons/flipqueue) (recommended)

When FlipQueue is installed, Tally reads its sales log read-only and surfaces sales history, active auctions, and posting failures in `/tally research`. FlipQueue keeps owning the writes; Tally complements with the analytics view.

### Sibling cogs in the [Cogworks](https://addons.wago.io/addons/cogworks) suite

Tally ships alongside [Cogworks](https://addons.wago.io/addons/cogworks) (shared library), [FlipQueue](https://addons.wago.io/addons/flipqueue) (auction-house workflow), [Tempo](https://addons.wago.io/addons/tempo) (daily/weekly task cadence), and [Maxcraft](https://addons.wago.io/addons/maxcraft) (profession planning). Each is fully functional standalone; together they share the suite-wide minimap chrome and themable UI.

---

## Roadmap

In active development, in priority order:

- **Item Research panel** — bring `/tally research` out of chat into a proper UI with sparklines for price + inventory history and per-character drill-downs
- **History settings UI** — interval / retention / rollup controls in the main frame instead of via chat
- **Run-rate analytics** — `consumption vs. sales` flow metrics. How much Aether Vellum am I burning per week?
- **Sales ledger migration from FlipQueue** — eventually Tally absorbs FlipQueue's transaction log and becomes the authoritative ledger for the suite, exposing a canonical read API for cross-cog analytics
- **Profit/loss dashboard** — built on top of ledger × pricing history once the migration lands

---

## Requirements

- **WoW Retail** (current expansion)
- **[Syndicator](https://addons.wago.io/addons/syndicator)** is a hard dependency — Tally uses it as the single source of truth for inventory across all your characters

Recommended (greatly enhanced experience but optional):
- **[TradeSkillMaster](https://addons.wago.io/addons/tradeskillmaster)** for pricing
- **[FlipQueue](https://addons.wago.io/addons/flipqueue)** for sales history in `/tally research`

---

## Getting Started

1. Install Tally alongside [Syndicator](https://addons.wago.io/addons/syndicator) and (optionally) [TradeSkillMaster](https://addons.wago.io/addons/tradeskillmaster)
2. `/tally show` — opens the main frame with the net-worth-over-time chart
3. `/tally networth` — chat-based net-worth summary with per-character breakdown
4. `/tally research <itemlink-or-id>` — full record for any item
5. `/tally history` — see history config and snapshot stats; tune interval / retention / rollup as you like

---

## Feedback & support

GitHub issues are canonical: https://github.com/gezmodean-wow/tally/issues

Discord discussion happens in the **Cogworks** community.
