# Tally — Claude Code guidance

Tally is a cog in the Chronoforge WoW addon suite by Gezmodean (`gezmodean-wow` on GitHub), supported by the **Chronoforge** Discord community.

## What this cog does

Tally is the personal-finance layer of the Chronoforge suite — Personal Capital / Mint, but for WoW. It maintains an account-wide ledger of every sale and purchase, categorizes transactions, builds pricing history over time, calculates net worth across your full Syndicator-aware ownership graph (gold, items, WoW tokens, all linked accounts), and exposes per-item research that augments TSM, FlipQueue, and other auction-house data sources. Stance is **augment, not replace**: each sibling cog stays fully functional without Tally; installing Tally unlocks richer research, cross-account rollups, and pricing-history analytics for cogs that want them. FlipQueue's item-research and ledger sections will eventually migrate into Tally.

## Stack and conventions

- **No Ace3.** LibStub + CallbackHandler-1.0 + LibDataBroker-1.1 + LibDBIcon-1.0 + Cogworks-1.0.
- **Syndicator is a hard dependency.** Tally is inventory-aware and declares `## Dependencies: Syndicator` in the TOC. Consume `Syndicator.API` directly — no fallback scanner. Core.lua bails with a user-visible error if Syndicator isn't present.
- **Character keys use `"Name-Realm"` (Syndicator convention).** Use Cogworks's character-key helpers so persisted per-character data shares one keyspace across the suite.
- **Cogworks integration.** Registers with Cogworks via `LibStub("Cogworks-1.0", true)` when present. Keep Cogworks calls guarded — this cog must degrade gracefully if the library is absent.
- **Vendored libs.** All libraries except Cogworks-1.0 live directly in `Libs/`. Cogworks-1.0 is pulled at package time via a pinned-tag git external in `.pkgmeta`.
- **Additive Cogworks API use.** When using Cogworks, only rely on APIs that exist at or below the pinned tag. Bump the tag in `.pkgmeta` to pick up newer features — never rely on unpinned main.

## SavedVariables

- `TallyDB` — account-wide
- `TallyCharDB` — per-character

These names are reserved for this cog. Cogworks and sibling cogs (FlipQueue, Tempo, Maxcraft) never touch them.

## Slash commands

- `/tally` and `/tly` are reserved for this cog.

## Release flow

Tagged push → GitHub Actions (`release.yml`) → BigWigsMods packager → CurseForge + Wago.

Tag conventions (same as other cogs):
- `v0.1.0-alpha1` → alpha channel
- `v0.1.0-beta1` → beta channel
- `v0.1.0` → stable

Post-init manual steps before the first release:
1. Create the CurseForge and Wago project pages; paste the IDs into `tally.toc` (`X-Curse-Project-ID`, `X-Wago-ID`).
2. Add `CF_API_KEY` and `WAGO_API_TOKEN` to the repo's GitHub Actions secrets.
3. Confirm the `Cogworks-1.0` external tag in `.pkgmeta` matches the library version you intend to ship against.

## Repo layout

```
tally/
├── tally.toc                   # addon manifest
├── Core.lua                    # entry point — Cogworks registration, events, slash, LDB launcher
├── Util/
│   └── Items.lua               # canonical item-key parsing/matching (lifted from FlipQueue; replace once cogworks#6 lands)
├── Pricing/
│   └── Sources.lua             # TSM adapter + WoW Token special-case + vendor fallback
├── Inventory/
│   └── Ownership.lua           # Syndicator wrapper, per-char + warband rollup
├── NetWorth/
│   └── Calculator.lua          # configurable strategy (default DBRegionMarketAvg), snapshot + print
├── Research/
│   └── Aggregator.lua          # per-item record (superset of FlipQueue's); reads FlipQueue log when present
├── Libs/
│   ├── LibStub/                # vendored
│   ├── CallbackHandler-1.0/    # vendored
│   ├── LibDataBroker-1.1/      # vendored
│   ├── LibDBIcon-1.0/          # vendored
│   └── Cogworks-1.0/           # pulled via .pkgmeta at package time
├── .pkgmeta
├── .github/workflows/release.yml
├── CLAUDE.md
├── CHANGELOG.md
├── README.md
└── LICENSE
```

## Feedback tracking

**GitHub is canonical.** Issues live at https://github.com/gezmodean-wow/tally/issues — this is the single source of truth for bugs, feature requests, and engineering discussion. The `scribe` bot (deployed on Railway, source at `C:/src/scribe`) mirrors Discord forum activity into GitHub issues automatically and broadcasts engineering comments back to the Discord thread.

When shipping a fix for a tracked issue, post the engineering note as a comment on the GitHub issue via `gh issue comment <number> --repo gezmodean-wow/tally --body "..."`. Don't update Discord directly — scribe handles propagation.

Tally issue IDs use the prefix `TLY` (e.g. `TLY-001`). The GitHub issue number is the canonical identifier; the `TLY-N` ID is for commit-message convenience.

### Proactive capture

When the user mentions a bug, regression, feature idea, or improvement during normal work, offer to file or update the GitHub issue. Don't open issues unprompted; ask first. When shipping a fix for a tracked issue, offer to post a status comment to the GitHub issue.

Commit messages referencing a tracked issue should use `<type>(<ID>): <subject>` — e.g. `fix(TLY-004): guard LDB registration against missing minimap lib`.

### Player-facing close summaries

When closing a player-visible issue, add a `## Player summary` section to the issue body before clicking close. One short sentence, plain language — what changed for the player, not what code changed.

Scribe pulls this text into:
- The close announcement posted into the linked Discord thread.
- The bulleted "What changed" list in the next release announcement.

If you forgot before closing, you can put a fenced `release-notes` code block in the closing comment instead — same convention, first paragraph wins. Issues with no summary in either place render as `⚠️ no summary written` in the staff release draft; fix by editing the issue body and re-running `/release-redraft`.

## Cross-cog feature requests

When you spot a gap in a sibling cog's library while working here — most often Cogworks (the shared core) needing a new helper, event, or primitive — offer to file a GitHub Issue on that cog's tracker via `gh issue create --repo gezmodean-wow/<target-cog>`. Mention Tally as the source in the body so the maintainer can triage it as a cross-cog ask. Scribe will mirror it to the target cog's Discord forum where its players can follow along.
