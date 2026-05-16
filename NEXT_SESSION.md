# Tally — next session handoff

alpha19 shipped 2026-05-14. Since then a full architecture **redesign** was scoped and broken out into GitHub issues. The next session's work is the redesign — but the build-out plan should not be locked until tester feedback lands on the feedback issue (#76).

## State

- **Branch:** `main`, synced with `origin/main` (modulo this file's commit — see "Loose ends").
- **Latest tag:** `v0.1.0-alpha19` (at `95da...95d1099`), shipped 2026-05-14 → CurseForge + Wago.
- **Recent commits:** `eb2905b` changelog heading promotion · `8ab1b25` `docs/REDESIGN.md`.
- **Cogworks pinned at `v0.14.1`** in `.pkgmeta`.
- **Standards acknowledgments:** runbooks `2026-05-05a`, scribe player-facing `2026-04-30f`. Verified current 2026-05-16.

## The redesign — read this first

**`docs/REDESIGN.md` is the canonical design.** Tally stops being a *store* of transactions and becomes a *projection layer* over sibling sources (TSM, FlipQueue, Journalator): no native capture, no stored ledger, recompute-on-parse dedup/merge, persists only net-worth snapshots + aggregates. The Lua constant-pool wall is structurally gone because nothing persisted grows with row count. New navigation: a `Live · Historical · Tools · Settings · Appearance` left bar.

GitHub structure:
- **[#77](https://github.com/gezmodean-wow/tally/issues/77)** — engineering umbrella, with the 14-item task checklist.
- **Task issues [#78](https://github.com/gezmodean-wow/tally/issues/78)–[#90](https://github.com/gezmodean-wow/tally/issues/90)** + **[#72](https://github.com/gezmodean-wow/tally/issues/72)** (Appearance). Each links back to #77.
- **[#76](https://github.com/gezmodean-wow/tally/issues/76)** — tester feedback issue. A `## Player update` comment with 8 questions is posted; scribe mirrors it to the Discord thread.
- Supersedes **#73** (tab rework — should be closed in favour of #77). Reframes **#24** (→ Ledger reconciliation facet) and **#66** (→ no slots, CSV is the export format).
- **[flipqueue#203](https://github.com/gezmodean-wow/flipqueue/issues/203)** — cross-cog heads-up: FlipQueue's ledger no longer migrates into Tally; its data stays put.

## Gated on tester feedback

**Do not lock the build-out plan until #76 gets replies.** Questions 1/3/8 specifically gate real decisions: how long the Live window should be (#84), how hard the sibling dependency is, and whether the on-demand 2–3s parse latency is acceptable (#79). Watch #76's Discord thread for Toeknee / zong / zpectre.

## Suggested implementation order (once feedback lands)

Data spine before views:
1. **#79 parse cache + #80 dedup/merge engine** — the spine everything reads from.
2. **#81 net-worth snapshot store + #82 aggregates store** — the only persisted data.
3. **#78 retire the old store** — alongside/after the spine works.
4. **#83 nav shell + #84 historical date picker** — the frame.
5. **#85 Summary / #86 Ledger / #87 Research views, #88 minimap, #89 Tools, #72 Appearance.**
- **#90 multi-realm** is a data-model concern (realm dimension, buy/sell-side classification) that threads through #80/#82/#86 — settle its model decisions inside those, don't treat it as a late add.

## alpha cadence

Multi-alpha effort. alpha20 ≈ teardown + data spine; views land across alpha20–22. Phase internally via commits, tag per the cadence. Tester data is expendable — clean break, no migration.

## Loose ends

- **#73** should be closed (superseded by #77) — left open so a human confirms.
- This `NEXT_SESSION.md` commit may be local-only — push if a future session needs it.

## Live testers

- **Toeknee_atx** — primary big-roster tester (68 chars). **zong** — 53-char roster. **_zpectre_** — last known alpha15, worth a check-in; TLY-65 is his. Point all three at #76's Discord thread for redesign feedback.

## Open issues snapshot

- **#77** redesign umbrella · **#76** redesign feedback · **#78–#90, #72** redesign tasks.
- **#73** tab rework — close (superseded by #77).
- **#24** TSM-vs-Tally compare — reframed into #86; keep open until the Ledger reconciliation facet ships.
- **#66** CSV slots — reframed into #89's CSV exporter.
- **#65** zpectre divergence freeze — independent of the redesign; still open.
- **#69 / #70 / #71 / #68** — alpha19 shipped fixes; close after tester confirmation.
