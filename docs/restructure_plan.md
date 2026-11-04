# Restructure plan — streamlining for user-friendliness

> **Historical planning draft.** For the current code-verified scope, priority,
> migration requirements and acceptance gates, use
> [Nextup UX restructuring — verified execution plan](ux_restructure_execution_plan.md).
> This earlier draft predates the final Watch implementation audit: Reels is
> currently missing from Watch, IPTV startup and persisted navigation require
> migration safeguards, and Cloud consolidation is already complete.

Companion to `page_cohesion_map.md`. That map showed the app's **surfaces** are
cohesive (four theme-aware design systems). This plan is about **structure** —
where the app's *navigation and flows* stray from "one obvious place for each
job," and how to even them out without losing capability.

## The user-friendly bar we're measuring against

1. **One obvious entry per job.** Not several parallel top-level doors to the
   same kind of thing.
2. **Shallow, grouped nav.** Related destinations live under one hub, reached by
   progressive disclosure — not as a long flat bar.
3. **Hubs over duplicates.** A consolidation hub and the things it consolidates
   should not *both* sit at the top level.
4. **Consistent affordances within a family.** Same gestures/actions across
   sibling screens (shared base, not hand-wired each time).
5. **Findable settings.** Grouped by domain + search, not a wall of pages.

## Where it strays today (grounded in `lib/services/main_page_bridge.dart` + `main.dart`)

The nav has **21 slots** (`MainTab`), and the default phone bar carries ~11
destinations. The strays:

### A. Five parallel "lean-back" feeds at the top level 🔴 (biggest)
`Reels` (20), `IPTV` (13), `YouTube` (14), `Debrify TV` (3), `Stremio TV` (9) are
all "sit back and watch a stream/feed" surfaces, each its own top-level tab. A
user deciding "I just want something playing" faces five doors.

### B. Three discovery surfaces 🟠
`Home` (15, the board), `Discover` (18, source-dropdown browser), `Search` (17,
desktop-only). Overlapping jobs, three entries. The default phone bar even leads
with **Discover**, not Home.

### C. Cloud: a hub *and* six provider tabs 🟡
`Cloud` (16) already consolidates RD/Torbox/PikPak/WebDAV/Premiumize/AllDebrid,
and the default correctly uses it. But each provider is *also* a pinnable
top-level tab (4/5/6/10/11/12), so a power user ends up with a hub **and** its
members side by side — two models for one job.

### D. Provider browsers are hand-wired 🟡
The six cloud screens share `CloudScaffold` (surface) but **not** behavior — list,
row actions, gestures, empty/error states are re-implemented per provider
(`CODEMAP.md`: "No shared provider interface"). That's where affordances drift.

### E. Dead / deprecated slots 🟡
`MainTab` 0 is a *deprecated* Home kept as a dead slot; `screens/deprecated/
torrent_search_screen.dart` (26k lines) and its only-there widgets
(`catalog_browser`, `aggregated_search_results`, `trakt_results_view`) are legacy.

### F. Settings sprawl 🟡
~73 settings pages. `settings_search` exists (good) — the risk is discoverability
and a flat mental model, not missing features.

## Phased restructure (prioritized by impact ÷ risk)

### Phase 1 — A single "Watch" hub for the feeds 🔴 highest impact — ✅ DONE
Grouped the five lean-back feeds (Reels, IPTV, YouTube, Nextup TV, Stremio TV)
behind one top-level **Watch** destination (`MainTab.watch` = 21,
`WatchHubScreen`) that opens each feed as a pushed route via
`MainPageBridge.openFeed` — mirroring exactly how the Cloud hub opens providers.
The feed *screens* are untouched (built by the same `_buildTabContent`, so the
resolved TV flag and behavior carry over). Removed the five feeds from all three
`_computeVisibleNavIndices` branches, from `_phoneNavDefaultOrder`, and from the
`sidebarDestinations` catalog; Home's "watch this favourite channel" shortcuts
now route through `openFeed` too.
- **Result:** default bar drops from ~11 to ~7 entries; "I want something on" is
  one door. `lib` analyzes clean; sidebar/nav tests updated and green.
- **Needs your eyes:** desktop rail/pill + (if you ship it) the TV D-pad and the
  phone bar — the five layouts a static check can't see.

### Phase 2 — Make Cloud the only cloud door 🟡
Demote the six individual provider tabs to **in-hub** navigation only; replace
"pin provider to nav" with "set my default provider" inside the hub. The hub
already has the `*HiddenFromNav` flags and `CloudScaffold` — this is tightening a
default, not new plumbing.
- **Win:** one model for cloud, not two. **Risk:** low; power users lose a
  shortcut but gain consistency (offer an in-hub default + deep-link).

### Phase 3 — Clarify the discovery trio 🟠
Define and enforce roles: **Home** = the curated board (and the search entry
lives *on* it, via the existing "phone reaches search from the Home board"
pattern); **Discover** = the source-dropdown browser, folded into Home as a
*mode/row* rather than a separate tab; **Search** stays a wide-layout convenience.
- **Win:** one discovery home, fewer near-duplicate tabs. **Risk:** medium — Home
  is the busiest screen; do it behind its existing tests + a visual check.

### Phase 4 — Shared `CloudFilesScaffold` behavior base 🟡
Lift the common provider-browser behavior (row model, context actions, multi-
select, gestures, empty/error/loading states) into one base the six screens
extend — so they share *affordances*, not just the surface. Adopt incrementally
(newest provider, AllDebrid, is the template per `CODEMAP.md`).
- **Win:** consistent cloud UX + far less drift. **Risk:** medium, but per-screen
  and test-guardable; ship one provider at a time.

### Phase 5 — Settings grouping + "Advanced" 🟡
Keep `settings_search` prominent; group pages by domain (Playback, Providers,
Trackers, Appearance, TV, Advanced) and tuck rarely-touched pages under
**Advanced** so the top level is short.
- **Win:** findability. **Risk:** low (reorganizing entries, not logic).

### Phase 6 — Retire dead slots 🟢 cleanup
Remove the deprecated Home slot (`MainTab` 0) and, once Phases 2–3 land, delete
`deprecated/torrent_search_screen.dart` + its exclusive widgets — which also
lets `catalog_item_detail_screen` shrink to just its Stremio-TV tune-in role.
- **Win:** less dead weight. **Risk:** low *if* nothing live still imports them
  (verify first).

## Prioritization

| Phase | What | Impact | Risk | Order |
|---|---|---|---|---|
| 1 | "Watch" hub for the 5 feeds | 🔴 high | low | **first** |
| 2 | Cloud = only cloud door | 🟠 med | low | second |
| 6 | Dead-slot cleanup | 🟢 low | low | alongside 2 |
| 3 | Collapse discovery trio | 🟠 med | med | third |
| 4 | Shared cloud behavior base | 🟡 med | med | incremental |
| 5 | Settings grouping | 🟡 med | low | anytime |

## Non-goals (don't "even out" these — they're right)

- **Don't merge the four design systems** (Glass / Cloud / TV / Settings). Each
  fits its context; cohesion ≠ uniformity.
- **Don't retire `catalog_item_detail_screen`'s tune-in** — it serves Stremio-TV's
  channel commit, a different job from the browse detail.
- **Don't flatten the player/HUD** — its dock system is its own coherent surface.

## Already done (this cohesion pass)

- Downloaded shows open the same Showcase detail as Home; inline per-episode
  delete; "Downloaded" → the download manager; ambient-trailer playback crash
  fixed at root.
- Download manager merged into one glass scroll (`DOWNLOADING`/`DOWNLOADED`), hard
  `TabBar` + dead `TabController` removed.

---
_Structure plan; pair with `page_cohesion_map.md` (surfaces) and `CODEMAP.md`
(files). Phases are independent — ship them one at a time behind the existing
screen tests._
