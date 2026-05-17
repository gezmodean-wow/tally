# Tally — next session handoff

alpha19 shipped 2026-05-14. The active workstream is the **projection-layer redesign** (umbrella #77). The data spine is now functionally complete in code; the remaining build-out is the verification UI, then persistence, then the teardown and the new navigation/views.

## State

- **Branch:** `main`. **7 commits ahead of `origin/main`, unpushed.** Push needs explicit approval.
- **Latest tag:** `v0.1.0-alpha19`, shipped 2026-05-14. alpha20 not yet tagged.
- **Cogworks pin:** `.pkgmeta` external at **`v0.14.2`**. Local `Libs/Cogworks-1.0/` is gitignored/package-time — still v0.14.1 until re-fetched.
- **Standards acknowledgments:** runbooks `2026-05-05a`, scribe player-facing `2026-04-30f`. The player-facing doc was WebFetched 2026-05-17 — top changelog entry still `2026-04-30f`, no update needed.

## The redesign — read this first

**`docs/REDESIGN.md` is the canonical design.** Tally stops being a *store* of transactions and becomes a *projection layer* over sibling sources: no native capture, no stored ledger, recompute-on-parse dedup/merge, persists only net-worth snapshots + aggregates + sparse manual overrides.

GitHub: **[#77](https://github.com/gezmodean-wow/tally/issues/77)** umbrella (14-item checklist) · task issues **[#78](https://github.com/gezmodean-wow/tally/issues/78)–[#90](https://github.com/gezmodean-wow/tally/issues/90)** + **[#72](https://github.com/gezmodean-wow/tally/issues/72)**.

## Done this session — the data spine (4 commits)

The architecture was planned first (Plan agent), then built as **additive** modules under a new `Spine/` directory — nothing in the live addon changed behaviour. All four commits syntax-check clean (`luac -p`). No player-visible behaviour yet beyond the `/tally spine` diagnostic.

- **`f2032c0` feat(TLY-80) — dedup/merge pure core.** `Spine/Dedup.lua` (`ns.Spine.Dedup`): pure recompute-on-parse dedup/merge — coarse-key bucketing (`kind|itemID|charKey|count|counterparty`) + windowed clustering with the source-uniqueness gate ported from `Ledger.clusterGroup`, so distinct same-source events never collapse. **Price is a tolerance-gated match constraint, not a key field** — keying on exact price would split the records whose prices conflict and hide the conflict; instead near-prices merge and flag, far-apart prices stay distinct (user-confirmed design call). Field-merge reuses `ns.Ledger:GetAuthority`. `Spine/Overrides.lua` (`ns.Spine.Overrides`): the one persisted piece — sparse manual corrections in a new `TallyDB.merge` sub-key, keyed on relog-stable `Dedup.entryKey`.
- **`18cf1fc` feat(TLY-79) — session parse cache.** `Spine/ParseCache.lua` (`ns.Spine.ParseCache`): parses each sibling source once per session via its `getEntriesFn`, chunked one-source-per-tick, `generation`-guarded. **Lazy, not login-eager** — deliberately NOT hooked into `PLAYER_LOGIN` (an unconditional login parse would re-create the flipper-loop relog tax the alpha18 rewrite removed); populates on first demand. `TallyDB.spine.enabled` escape-hatch flag, default on. New `/tally spine` slash command (`parse`/`status`/`on`/`off`).
- **`6619aff` feat(TLY-80) — projection API.** `Spine/UnifiedLedger.lua` (`ns.Spine.UnifiedLedger`): the read surface views call — `Query(filter)`, `GetReviewList()`, `Stats(filter)`, `IsReady()`. Memoized recompute, invalidated when the parse cache refreshes. **Realm dimension (#90)**: every record gains `realm = { key, side }` (key from the charKey, normalized via Cogworks; side buy/sell/neutral from kind).
- **`e4482cf` feat(TLY-79) — parse loading bar.** `UI/ParseProgress.lua`: listener on `ParseCache` rendering the parse via `ns.UI.CreateProgressBar`. Satisfies toeknee's #76 Q8 requirement (2-3s parse OK only if a loading bar shows).

**Data flow now in place:** `ParseCache → Dedup → Overrides → realm dimension → UnifiedLedger:Query`. Verify in-game with `/tally spine parse`.

## Next work — Commit 5: the spine verification UI (#77 checklist)

The one remaining piece of the spine build-out: a **gated "Spine" verification view** — a `MainFrame` page rendering `UnifiedLedger:Query` + the `GetReviewList` flag-for-review list, so testers can diff spine output against the live `LedgerPage` before #78 retires the old store. Model the gating on the existing **Compare tab** (`Core.lua` ~line 244 — `TallyDB.ui.showCompareTab`, registered conditionally; Settings toggle). New `UI/SpinePage.lua` + `tally.toc` line + `Core.lua` registration + a Settings toggle. The page should trigger `ParseCache:Ensure()` on open (this is the lazy auto-trigger — the loading bar fires here) and show a spinner while `UnifiedLedger:IsReady()` is false.

Then, per the #77 order: **#81/#82 (persistence — net-worth snapshots + aggregates)** → **#78 (retire the old store)** → **#83/#84 (Live/Historical nav)** → **#85/#86/#87 views, #88 minimap, #89 tools**. #78 must come AFTER persistence — retiring the store first leaves Tally with no ledger data.

## Loose ends

- **Check `- [x] #72` on the #77 umbrella checklist** — still unchecked (needs a `gh` remote write; approval).
- **7 unpushed commits on `main`** — push when ready.
- **#72 not smoke-tested in-game** — renders on the fallback path on stale v0.14.1; re-fetch the `.pkgmeta` external at v0.14.2 to exercise the real `CreateAppearanceTab`.
- **Spine not smoke-tested in-game** — all four commits are syntax-checked only. First in-game check: `/tally spine parse` should show the loading bar and a non-zero unified-record count.

## Tester feedback (#76)

**toeknee replied** (zong / zpectre have not). Key answers: looks back ~30d, mostly leans on TSM for detail; runs TSM + FlipQueue (TSM keeps 1yr); net worth = everything-sellable + all gold; **84 buy realms / 25 sell realms**; minimap wants gold (toons/warbank/GB) + items (toons/AH/warbank) + grand total; **2-3s parse pause OK if a loading bar shows** (drove `UI/ParseProgress.lua`). Still waiting on zong / zpectre before locking the Live-window length (#84).

## alpha cadence

Multi-alpha. alpha20 ≈ teardown + data spine; views land across alpha20–22. Phase internally via commits, tag once. Tester data is expendable — clean break, no migration.

## Live testers

- **Toeknee_atx** (68 chars) · **zong** (53 chars) · **_zpectre_** (last on alpha15; TLY-65 is his). Point all three at #76's Discord thread.

## Open issues snapshot

- **#77** umbrella · **#76** feedback · **#78–#90, #72** tasks. #72 + the spine core (#79/#80/#90) are code-complete; #79/#80 stay open until the verification UI + persistence land.
- **#73** tab rework — close (superseded by #77).
- **#24** → reframed into #86 · **#66** → reframed into #89 · **#65** zpectre divergence — independent, still open.
- **#69 / #70 / #71 / #68** — alpha19 shipped fixes; close after tester confirmation.
