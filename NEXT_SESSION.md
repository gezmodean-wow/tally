# Tally — next session handoff

alpha19 shipped 2026-05-14. The active workstream is the **projection-layer redesign** (umbrella #77). Design is captured, the work is broken into GitHub issues, and the first task (#72) has landed. The build-out plan is still gated on tester feedback (#76).

## State

- **Branch:** `main`. **2 commits ahead of `origin/main`, unpushed** — `e909cf0` (NEXT_SESSION refresh) and `6d1470f` (#72). Plus this handoff commit. Push needs explicit approval.
- **Latest tag:** `v0.1.0-alpha19`, shipped 2026-05-14.
- **Cogworks pin:** `.pkgmeta` external now at **`v0.14.2`** (bumped from v0.14.1 by #72, for `cw:CreateAppearanceTab`). The local `Libs/Cogworks-1.0/` checkout is gitignored/package-time — still v0.14.1 until re-fetched.
- **Standards acknowledgments:** runbooks `2026-05-05a`, scribe player-facing `2026-04-30f`. Verified current 2026-05-16.

## The redesign — read this first

**`docs/REDESIGN.md` is the canonical design.** Tally stops being a *store* of transactions and becomes a *projection layer* over sibling sources (TSM, FlipQueue, Journalator): no native capture, no stored ledger, recompute-on-parse dedup/merge, persists only net-worth snapshots + aggregates. New navigation: a `Live · Historical · Tools · Settings · Appearance` left bar.

GitHub structure:
- **[#77](https://github.com/gezmodean-wow/tally/issues/77)** — engineering umbrella with the 14-item task checklist.
- **Task issues [#78](https://github.com/gezmodean-wow/tally/issues/78)–[#90](https://github.com/gezmodean-wow/tally/issues/90)** + **[#72](https://github.com/gezmodean-wow/tally/issues/72)** (Appearance).
- **[#76](https://github.com/gezmodean-wow/tally/issues/76)** — tester feedback issue; `## Player update` comment posted, mirrored to Discord.
- Supersedes **#73**; reframes **#24** and **#66**. Cross-cog heads-up filed: **[flipqueue#203](https://github.com/gezmodean-wow/flipqueue/issues/203)**.

## Done this session

- **#72 Appearance tab** — committed `6d1470f`. New `UI/AppearancePage.lua` (`ns.UI.CreateAppearancePage`) wraps the shared Cogworks appearance primitive with `{ cog = "Tally" }`; registered in `Core.lua` after Settings, added to `tally.toc`. Builder call prefers `cw:CreateAppearanceTab`, falls back to `cw:CreateUIScalingSettingsBlock` (works on stale v0.14.1). `.pkgmeta` bumped to v0.14.2. CHANGELOG + RELEASES updated under Unreleased. Lua syntax-checked clean.

## Loose ends to clear early

- **Check `- [x] #72` on the #77 umbrella checklist.** The edit was started but interrupted — the box is still unchecked.
- **#72 not smoke-tested in-game.** The fallback means it renders on the local v0.14.1 lib; to exercise the real `CreateAppearanceTab` path, re-fetch the `.pkgmeta` external at v0.14.2. New tab appears last in the main-frame tab strip.
- **2 (soon 3) unpushed commits on `main`.** Push when ready.

## Next work — the data spine

The correct next chunk is the data spine: **#79 (session-lifetime parse cache)** + **#80 (dedup/merge engine)**. Both are feedback-independent in their core design and can be built as *additive* modules without breaking the current addon. **They are the architectural core — start with a Plan, not code.** Then #81/#82 (persistence). **#78 (retire the old store) must come AFTER the spine works, never before** — retiring it first leaves Tally with no ledger data until the spine + persistence land.

Order: #79 + #80 → #81 + #82 → #78 → #83 + #84 (nav) → #85/#86/#87 views, #88 minimap, #89 tools, #90 multi-realm model. #90 is a data-model concern threading through #80/#82/#86 — settle it inside those.

## Still gated on tester feedback

Do not lock the build-out plan until #76 gets replies. Questions 1/3/8 gate the Live window length (#84), the sibling-dependency assumptions, and the on-demand parse-latency tradeoff (#79). Watch #76's Discord thread for Toeknee / zong / zpectre.

## alpha cadence

Multi-alpha effort. alpha20 ≈ teardown + data spine; views land across alpha20–22. Phase internally via commits, tag once. Tester data is expendable — clean break, no migration.

## Live testers

- **Toeknee_atx** (68 chars) · **zong** (53 chars) · **_zpectre_** (last on alpha15; TLY-65 is his). Point all three at #76's Discord thread for redesign feedback.

## Open issues snapshot

- **#77** umbrella · **#76** feedback · **#78–#90, #72** tasks (#72 code-complete, committed).
- **#73** tab rework — close (superseded by #77).
- **#24** → reframed into #86 · **#66** → reframed into #89 · **#65** zpectre divergence — independent, still open.
- **#69 / #70 / #71 / #68** — alpha19 shipped fixes; close after tester confirmation.
