# Full-page cohesion map

A page-by-page map of the app's **complex full-page screens** and the design
system each belongs to, so a cohesion pass targets real divergence instead of
re-styling screens that are already consistent through a shared system.

> Companion to `CODEMAP.md` (area → files). This one is **page → design system**.

## The app has FOUR intentional, theme-aware design systems

Each is internally consistent and already follows the selected app theme
(including frosted glass). "Cohesion" means a page belongs cleanly to one of
these — not that every page looks identical.

1. **Glass** — `GlassChrome.*` frosted chrome. Home/Discover, the detail page,
   downloads, the download manager, calendar, playlist content.
2. **Cloud** — `CloudScaffold` + `app.cloud.*` (indigo radial bloom, deliberately
   mirroring the Home board). The six provider file browsers.
3. **TV (10-foot)** — Debrify TV, Stremio TV, TV player controls.
4. **Settings** — the settings design system (`settings/*`).

Global `ThemeData` already does a lot of the cohesion work:
`appBarTheme` glass-fills + themes every `AppBar`; `cardTheme` glass-styles every
`Card`; inputs, dialogs, popups, snackbars all derive from the theme. So a stock
`AppBar` or `Card` is **not** a divergence — it inherits the theme.

## Page inventory

### Glass system (reference surfaces)
- **`search_screen`** — Home/Discover board. The reference look.
- **`merged_series_detail_screen`** — the one real detail page (Showcase/Classic).
  Home, Downloads and IPTV all route here.
- **`downloads_screen`** — device library (reuses the Discover grid).
- **`download_manager_screen`** — queue + transfers; **one glass scroll**
  (Downloading → Downloaded), no tab swap.
- `trakt_calendar_screen`, `playlist_content_view_screen`, `metadata_explore_page`,
  `media_server_library_panel`, `reels_screen`.

### Cloud system (provider file browsers) — cohesive via `CloudScaffold`
All six use `CloudScaffold` + `CloudPageBackground` + `app.cloud.*`, so they share
the indigo-bloom surface and follow the theme. (`lib/widgets/cloud/cloud_theme.dart`
documents that the six "read as the same app".)

| Provider | Screen | `CloudScaffold` |
|---|---|---|
| Real-Debrid | `debrid_downloads_screen` | ✅ |
| Torbox | `torbox/torbox_downloads_screen` | ✅ |
| PikPak | `pikpak/pikpak_files_screen` | ✅ |
| Premiumize | `premiumize/premiumize_files_screen` | ✅ |
| AllDebrid | `alldebrid/alldebrid_files_screen` | ✅ |
| WebDAV | `webdav/webdav_files_screen` | ✅ |
| hub | `cloud_screen` | links to all of the above |

> A raw `grep GlassChrome` scan shows "0" here and is **misleading** — these pages
> use the cloud system, not the glass one, on purpose. The residual `Color(0x…)`
> literals are mostly semantic accents (danger red `#EF4444`, status green,
> provider brand hues).

### Detail pages
- **`merged_series_detail_screen`** — the title-**browse** surface (season tabs,
  episode list, resume, quick-play, download, trackers). Home, Downloads and IPTV
  route here. ✅
- **`catalog_item_detail_screen`** — NOT a duplicate to retire. It serves a
  different job: Stremio-TV's channel **tune-in** (both buttons `_playChannel`,
  `enablePrimarySourcesHold: false`, no episode/source browsing). Forcing the
  browse surface onto a live-channel commit would be *less* cohesive with the
  feature's meaning, and would fire episode/addon loads tune-in never needs. It
  already uses `DetailAtmosphere`/`DetailThemeScope`, so it's in the glass family.
  Its other references (`catalog_browser`, `aggregated_search_results`,
  `trakt_results_view`) live only in the **deprecated** search screen.
  *Optional cosmetic follow-up:* swap its `Color(0x…)` literals for theme tokens so
  it tracks the selected theme as tightly as the rest.
- `episodes_screen`, `iptv/xtream_series_detail` — thin wrappers → `EpisodesPanel`
  / `MergedDetailScreen`. ✅

### TV system
- `magic_tv_screen`, `stremio_tv/*`, `debrify_tv/*` — own 10-foot design. ✅
  internally; do **not** impose the glass detail chrome on these.

### Settings system
- `settings_screen` + `settings/*` — own settings design system. ✅

### Other
- `addons_screen` — tabbed (**Stremio Addons** vs **Torrent Engines**): two
  distinct content sets, so tabs are appropriate (not a merge candidate).
- `see_all/*` — share `SeeAllPosterGrid`; chrome is light but theme-inherited.
- `browse_screen`, `playlist_screen`, `collections/*`, `profiles/*`.

## Genuine cohesion gaps (what's actually worth doing)

1. **🟡 Semantic-colour literals** (`#EF4444` etc.) in the cloud screens and
   `catalog_item_detail`. Low visual impact (danger/status/brand accents), worth a
   token sweep only alongside other edits in those files.

Note: the two detail *screens* are **not** a gap — `merged_series_detail_screen`
browses a title and `catalog_item_detail_screen` serves Stremio-TV's channel
tune-in (a deliberately different interaction). Keeping both is correct; see
"Detail pages" above.

Everything else the earlier scan flagged (provider screens "not glass", stock
`AppBar`s, `Card`s) is **already cohesive** through the shared systems above.

## Done in this pass

For navigation and workflow changes beyond visual cohesion, see the
[verified UX restructuring plan](ux_restructure_execution_plan.md). It corrects
the current Watch/Cloud status and documents navigation migration safeguards.

- `download_manager_screen`: merged In-Progress/Finished into one glass scroll
  with `DOWNLOADING`/`DOWNLOADED` headers; removed the hard `TabBar` (and its dead
  `TabController`).
- Downloaded-show detail: routed to the same Showcase surface as Home, inline
  per-episode delete, "Downloaded" → download manager, no ambient-trailer crash.
- `pipeline_loading_overlay`: the Marquee play-search surface retains its
  cinematic four-stage layout while its backdrop tint, accent bloom, provider
  chip and Cancel chrome follow the launching app theme (including shape/glass
  preferences). Text ink is explicitly legible on its dark plate even under
  paper/light themes. RawDialogRoute still snapshots the launcher's theme,
  including Stremio TV's intentional legacy freeze. Legacy artwork grading is
  unchanged; the original stage/cancellation behavior is preserved.

### Current cross-page and player cohesion (October 25, 2026)

The latest integrated acceptance run passed 199 playback/loader/glass/native
recovery tests and 91 navigation/discovery/Cloud/Settings tests; targeted
analyzer found no issues. A fresh end-to-end movie playback screenshot and
actual Android TV/tvOS video/remote/HDR testing remain open release gates.

- **One actual Spotlight media identity across all four runtime surfaces:**
  `lib/widgets/home/spotlight_media_identity.dart` is now consumed by Home's
  wide/flipped and compact hero, the Showcase title-detail identity,
  Marquee preparation and the in-app player. The former duplicated Home and
  detail `_LogoOrTitle` implementations have been removed. All four use
  `OpticalLogo` geometry (480×104 bounding slot, equal optical logo area,
  reserved placement) and its 39px/w800 text alternative. The shared block
  presents real IMDb ratings, the *episode label within the metadata row*
  directly beneath the logo (never as a separated top eyebrow), year,
  duration, certification, genres and the available synopsis. The four pages
  use the same `SpotlightMediaLogo`, metadata row and synopsis styling,
  replacing mismatched 150–250px art and typographic hierarchy. The
  **`SpotlightEditorialSignals` is part of this very component**: IMDb's
  original fine outlined score, Rotten Tomatoes, Metacritic, IMDb Top 250 and
  trending rank/direction share the same hairline enclosure and responsive
  wrap; no yellow block and no detached detail-only ratings or honors row.
  Source values come from existing IMDb enrichment and quota-bounded OMDb
  ratings when available; IMDb's Metascore remains usable without OMDb.
  Invalid/unavailable values are hidden rather than manufactured. Only
  route-specific context, such as expandable synopsis, MDBList status
  and the precise trailer tap anchor, uses child slots. Home's flip/phone
  alignments remain supported;
  the loader uses Home/Showcase's 84/1920 wide and 4.8% compact gutters.
  No screenshots or generated graphics substitute for runtime content. The
  loader appends actual source-search/cache/preparation/start progress,
  provider badge and Cancel below the spotlight block; the player anchors
  its identity over a subtitle/transport-safe lower-left region, removes
  duplicate top title/rating chrome for movie/episode playback and keeps live
  channel/source UI separate. Both must retain responsive/focus and provenance
  gates and keep their active/Legacy theme behaviors.

- **Fresh integrated UX validation (October 25):** 136/136 widget/contract
  tests passed in the later combined regression including all four Spotlight
  consumers, editorial-score rendering and mocked provider-auth failure,
  Source Prepare's
  responsive/theme/cancel states, real Home→Explore navigation, Watch/Reels,
  Cloud, saved sidebar migrations, Settings and metadata browse sorting.
  Targeted analyzer for the changed identity/Home/detail/overlay paths had
  zero issues. `test/spotlight_four_surface_identity_2026_test.dart` checks
  both source-level wiring and runtime logo/metadata/extension alignment.
  Additional `test/spotlight_editorial_signals_2026_test.dart` validates
  accurately enclosed IMDb, RT, Metacritic, Top 250 and trending readouts,
  invalid/missing values, source fallback and narrow layout; the source
  cannot use a provider API's absence to infer a score or rank.
  This evidence is not a live stream or device-rendered snapshot.

- **TorBox 403 recovery:** `TorboxAuthorizationException` identifies rejected
  API authentication without exposing headers or provider payload. Quick Play
  applies a per-attempt provider circuit breaker across source and pack probes,
  can select only truly resolved playable direct/authorized alternatives,
  and exits the source loader with an actionable account/Settings remedy when
  none can play. `test/quick_play_torbox_auth_failover_2026_test.dart` uses a
  fake 403 provider transport. Reconnection of the user's actual provider
  credentials, live-provider confirmation and player video output remain
  outside the reach of deterministic tests.

- **Liquid Glass follow-on:** the active macOS Skia player fallback now applies
  live-backdrop 1.045× matrix lensing rather than an invisible 1.012× shift,
  lower 1.5–5px frost and stronger yet restrained painted red/blue rims.
  The Impeller optical tokens now use 4.8/6px bounded rim refraction and
  1.25/1.6px color-channel offsets with a 5px maximum residual shader blur.
  Tests assert the Skia moving backdrop filter, reduced-motion/focus behavior,
  shader program loading and JSON/default token matching. A Mac preview
  process is present, but the actual moving native video texture and HDR
  behavior still require physical screenshot/motion verification.

- **Screenshot-driven player parity correction (October 25):** a real 1649×922
  video screenshot showed the title/episode overlay starting near the center
  because `left = (viewport.width - 560) / 2`; the matching title-detail hero
  was left-aligned near x=72. The player now uses an explicit 72/42/24px
  responsive *left* gutter (wide/TV/phone), raises the bottom-left identity
  over the dock by 30px on wide screens and scales **only optical title art**
  1.5× on wide surfaces, keeping metadata and synopsis at their normal size.
  Both surfaces share `SpotlightMediaIdentity`. A numeric episode guide rating
  has no established IMDb provenance and no longer replaces the series IMDb
  score under an IMDb-branded badge. These layout/provenance changes are
  covered by focused player/widget tests, not yet by live-stream screenshots.

- **Home / Explore / Search:** Home offers visible shortcuts to Explore,
  downloaded titles and Cloud files subject to the current profile; the
  catalog browse area is labelled Explore while retaining stable `discover`
  preference identity. Search remains the explicit query journey. A full
  Library tab and retirement of numeric legacy navigation are not approved.
- **Cloud hub:** Cloud's deliberate indigo identity survives the active theme,
  while the hub distinguishes disconnected, connected, hidden and paused
  providers. Hide means suppress a tile, not remove the connection; Restore
  and Manage connections preserve access to a reconfiguration path.
- **Settings:** retain the separate, searchable grouped experience. Platform
  scope descriptions and storage now distinguish wide navigation from compact
  phone style; a navigation visibility search can focus the actual toggle.
- **Player:** frosted controls belong to the TV/player chrome, not wholesale
  Glass/Cloud restyling. Opt-in Impeller liquid refraction samples the
  *current* backdrop in the clipped moving control bounds, with restrained
  chromatic edge dispersion and a softer frost/tint. Skia, high-contrast and
  unsupported native video-compositing paths require a legible, lightweight
  blur/frost fallback. A screenshot/mockup is **not** sufficient evidence that
  a platform video texture refracts; real-video motion/HDR/focus checks remain
  open. The now-implemented bottom-left movie/episode information surfaces
  preserve a transport/subtitle safe band, adapt to narrow/short viewports,
  and use logo, genuinely sourced IMDb rating and the current episode plot
  where available. The top-right suggestions panel leaves the credit roll
  playing and shows similar unwatched titles when no next episode is known;
  confirmed Next Episode takes precedence, and recommendations for a series
  require a confirmed season/series guide boundary.
- **Renderer-specific player glass:** the macOS preview uses Flutter 3.44,
  which cannot assume Impeller. The active player material supplies bounded
  LIVE-backdrop matrix displacement and restrained frost on Skia; the
  Impeller-only shader supplies corner-aware normal refraction/chromatic rim,
  with a shared modest 10Hz phase that stops for inactive surfaces and reduced
  motion. Stronger visual effects remain in the chrome, never rendered over
  the actual content as a fake screenshot; native video texture compatibility
  and HDR still require an actual device check.
- **Watched lifecycle:** completion state and provider watchlist cleanup are
  distinct from route EOF navigation. Movies leave Continue Watching at the
  watched threshold, but the viewer only returns to its origin at real EOF;
  series retain an actionable next episode, and live stream EOF is recovery,
  not a watched movie. No movie completion should delete a cloud file. The
  actual watched coordinator now records a durable **profile-scoped pending
  watchlist journal**, keeps Trakt/MDBList actions scoped to the watchlist,
  and uses safe Simkl Completed/Hold transitions rather than its destructive
  `/sync/history/remove` endpoint. Failed offline attempts retry upon later
  sync/playback; explicit re-add cancels earlier cleanups. An idle auth change
  is not yet a trigger on its own.

---
_Assessment is design-system aware, not scan-count driven. Companion: `CODEMAP.md`._
