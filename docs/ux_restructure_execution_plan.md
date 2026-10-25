# Nextup UX restructuring — verified execution plan

Status: **living execution plan**. The source changes described below are made
in the shared working tree; this document is not a release confirmation.
Basis: docs/page_cohesion_map.md, docs/restructure_plan.md, and the current Flutter implementation inspected 25 October 2026. Existing worktree changes are preserved.

### Current P0 correction and visual cohesion — 25 October 2026

The latest user-reported Prepare stall follows a TorBox HTTP `403 AUTH_ERROR`
after successful torrent discovery/cache detection. A cached hash is not a
playable authorization grant. `TorboxService` now emits a sanitized typed
authentication error for rejected HTTP/JSON responses. The Quick Play
acquisition path carries a per-play TorBox circuit breaker across episode,
pack, pinned and player-resolution probes, so a terminal account rejection
does not trigger the same failing create request for every candidate. It can
try an already playable direct item or an independently authorized configured
provider, but does not turn external recommendations or IPTV misses into
streams and does not auto-queue PikPak downloads. On exhaustion, the loader
is dismissed and the user receives actionable account/Settings feedback.
Restoring a rejected credential requires a real TorBox account action.

The visual integration now uses **the same real `SpotlightMediaIdentity`** in
Home Spotlight (wide/compact), Showcase detail, Marquee preparation and the
player. Both private `_LogoOrTitle` copies were removed. Alignment, visual
logo sizing, metadata hierarchy, IMDb provenance and synopsis styling are
centralized, with compositional extension points for the detail's live
expanded summary, profile-specific tracker status, trailer hit-test anchor
and existing controls. IMDb, Rotten Tomatoes, Metacritic, IMDb Top 250 and
weekly Trending indicators are NOT compositional decorations outside the
surface: `SpotlightEditorialSignals` now draws those in the shared metadata
wrap with Showcase's original outlined ratings grammar on all four pages.
The source is actual IMDb enrichment plus the existing OMDb cache; values
missing or not IMDb-authored are not invented, and IMDb-enriched Metascores
work when no OMDb key is configured. The duplicate detail-only scores/ranks
have been eliminated. Home/Showcase/Marquee wide gutters use the same
84/1920 measure; compact layouts preserve their phone alignment and focus.
The loader's stages remain Search→Cache→Prepare→Start below the same media
identity, rather than becoming a different title banner.

**Fresh test evidence:** 136/136 combined UI/navigation/Spotlight/loader,
Quick Play 403, Liquid Glass and editorial metadata
regressions passed, including actual Home→Explore widget routes and the
new four-surface wiring/runtime test; analyzer for the shared/Home/Showcase/
Marquee source set returned zero issues. The separate 24/24 targeted
glass/editorial/token tests also passed. The focused TorBox test injects a
realistic `403 AUTH_ERROR` response using fake transport and tests cutoff,
legitimate alternatives and terminal error paths; it is not validation of
the customer's credential or real streamed video. Active macOS preview is
present, but no authorized end-to-end streaming or Android TV/tvOS video/GPU
render proof has been captured in this run. Do not mark those gates shipped.
The macOS Skia fallback's live filter moved from nearly invisible 1.012×
to a restrained 1.045× lens, reducing frosted opacity and increasing rim color
separation. Impeller shader tokens increased bounded refraction and RGB edge
dispersion while decreasing blur. Shader/native video texture visual parity
still needs a real macOS/TV moving-video check; widget tests cannot prove it.

## Implementation update — 25 October 2026

The first cohesion pass now includes:

- Reels remains independently pinnable through sidebar customization and
  classic-phone navigation while also appearing as **Clips** in the Watch hub.
  The other four TV feeds stay consolidated under Watch. Migration preserves
  old Reels selections and maps only retired TV feed shortcuts into Watch.
- Watch hub permissions and TV focus behavior are covered by focused widget
  tests. Numeric tab IDs remain stable for older entry points.
- TMDB person credits now filter movie and TV rows **before** pagination.
  The same metadata browse UI exposes server-backed **Popularity** and
  **Rating** sorting for TMDB Discover, person, studio and network pages;
  **Relevance** is additionally available for person credits in original
  credit order. Network browsing shows TV by design. Runtime filtering remains
  a separate filter; no runtime sort was added.
- IMDb GraphQL fallback credits currently expose only popularity order without
  usable per-result rating values, so unsupported rating sorting is hidden on
  that source.
- Empty Cloud hub now links to **Manage connections** for authorized users,
  instead of relying solely on instructional text.

Verification so far: metadata browse UI 14/14, metadata sorting/type regressions
11/11, sidebar migration 17/17, Watch hub widget tests 7/7, and navigation
compatibility helpers 5/5. Focused Flutter static analysis passed on the
final MainPage, navigation compatibility, Cloud and metadata changes. Actual
device smoke tests of TV focus, phone cold IPTV launch, and post-player
return remain Phase 0 release gates; automated helper checks do not replace
those platform tests.

### October 25 integration update — navigation, playback and player material

Implementation in the live, deliberately uncommitted working tree:

- **Home / Search / Explore:** `MainTab.discover` retains its stored numeric ID
  and sidebar `discover` preference key, but displays as **Explore**. Home and
  Spotlight offer a profile-gated **Explore catalogs** shortcut; wide Home also
  links to **On device** and **Cloud files**. Explore has a contextual Home
  return action. Search continues to mean explicit queries rather than a
  second recommendation board. No existing sidebar pins are forcibly changed.
- **Library access:** Downloads exposes a profile-gated Cloud shortcut without
  collapsing the transfer queue into a new unvalidated hub. Cloud remains
  navigable when no provider is connected or when all provider tiles are hidden,
  so setup/restore are not dead ends.
- **Cloud Phase 1:** connection, all-hidden, paused and disconnected states
  receive distinct copy/actions; hide is explicitly distinguished from
  disconnect; hidden providers can be restored; permitted users retain Manage
  connections access. Provider-key focus and profile-switch async invalidation
  are covered by `test/cloud_hub_navigation_cohesion_test.dart` (11 passing).
  Individual provider root Back consistency and a direct Connections leaf
  deep link remain open gates.
- **Settings Phase 5:** platform navigation style writes now affect the
  currently edited wide/compact preference, not both. Search for a specific
  sidebar destination focuses, highlights and scrolls to its visibility
  checkbox; compact editor makes phone visibility and desktop ordering scope
  explicit. All 11 categories, Spotlight and Legacy are retained. Settings
  combined tests 27/27 passing; focus targets for unrelated settings leaves
  remain future work.
- **Movie completion:** `FinishedMovieReconciliationService` persists local
  finished state, then best-effort removes only the movie from local/connected
  tracker watchlists and paused Continue Watching sessions. Local finished
  markers protect future watchlist and Continue Watching matching against
  stale provider snapshots. Android TV progress integrates this coordinator
  for single catalog movies, independent of which tracker is configured as
  watch-progress source; rejects missing duration, early false-EOF frames and
  other non-qualifying progress. Series and live playback retain separate
  semantics. `test/finished_movie_reconciliation_test.dart` and
  `test/native_movie_completion_policy_test.dart` cover normalization,
  preservation of other titles, rewatch and threshold evidence. Disconnected
  remote provider deletes are still **best effort**, not a guaranteed durable
  queue; real authorized-account retry remains a release follow-up.
- **Player Liquid Glass:** `GlassSurface` now uses an Impeller-gated,
  custom `BackdropFilter` refraction shader (`assets/shaders/player_liquid_glass.frag`)
  sampling the live Flutter-composited backdrop per moving control: local
  rounded-rect lensing, three color-channel samples with subtle rim
  dispersion, reduced gray opacity, and moderated frosted blur. The shader is
  registered in `pubspec.yaml`; optical tokens in
  `assets/design/glass_tokens.json` match compiled defaults. Skia, shader
  load failure, Legacy and high contrast retain legible bounded blur/solid
  fallbacks. `test/player_liquid_glass_cohesion_test.dart` includes real
  FragmentProgram asset compilation and tests on moving bounds/backgrounds.
  Actual Impeller rendering over live video/native textures, HDR brightness
  and mobile/TV GPU performance remain an **unverified release gate**.
- **Liquid Glass motion + Skia reality check (October 25):** the actual macOS
  SDK is Flutter 3.44.8, where Impeller is experimental and normally not
  enabled; a shader-only improvement therefore cannot explain or fix a flat
  desktop control panel. `liquid_glass.dart` now uses rounded-rectangle rim
  normals, subtle 10Hz motion in the Impeller-backed player chrome (clock
  stops without listeners and on app background; disabled for reduced motion
  and high contrast) and reduced panel opacity/tint. On macOS Skia/non-Impeller
  it performs a bounded 1.012× `ImageFilter.matrix` displacement of the LIVE
  Flutter-composited backdrop under the frosted glass; it does not pretend
  this affine fallback reproduces the shader's curved RGB refraction.
  `glass_dock.dart` also reduces heavy dark gradients and improves visible
  TV remote focus feedback. Worker isolated Flutter tests **24/24 passed**,
  targeted analyzer clean. This does NOT prove native media overlay pixels are
  sampled or that Impeller/macOS 3.44 preview is safe for all video sources;
  enabling Impeller globally is deliberately deferred pending live hardware
  testing. Source: https://docs.flutter.dev/perf/impeller and
  https://api.flutter.dev/flutter/dart-ui/ImageFilter/ImageFilter.shader.html.
- **In-player context and credits:** with transport controls visible, an
  adaptive bottom-left media surface shows the real logo (fallback title),
  sourced IMDb rating when valid and a succinct movie or *current episode*
  synopsis (never substitutions from stale show overview); narrow/short
  layouts suppress surplus text. Near known outro markers or a conservative
  closing window, compact user-actionable suggestions keep credits playing.
  Suggestions respect configured metadata sources, watched status and
  confirmed series finale; an actual Next Episode action has priority.
  Selecting a suggestion pops the player then opens its detail using the
  existing Home bridge. Standalone movies auto-return on **real EOF**, not
  on the earlier watched threshold; live, PiP, playlist, sleep and series
  next-up retain their specialized routes. `test/player_media_details_test.dart`
  covers info, watched filtering, end-credits and return policies.
- **Provider cleanup resiliency:** local watched state and list removal
  precede independent concurrent Trakt/Simkl/MDBList operations. Completion
  now writes a **durable, profile-scoped per-provider acknowledgement journal**
  before the local watched update; offline/auth failures stay pending for a
  later retry on ordinary watchlist sync or the next permitted non-trailer
  playback launch, even with global "Sync everywhere" disabled. A deliberate
  new My Watchlist add supersedes earlier pending removal and the sync snapshot
  cannot resurrect an older completed movie. Trakt/MDBList deletions are
  watchlist-only. **Simkl's `removeFromList` invokes history removal** and was
  unsafe here: completed movies move Plan to Watch → Completed using Simkl's
  supported status action, preserving watched history; a general un-save
  transitions Plan to Watch → Hold. A provider/account update without any
  subsequent app action is not an automatic retry trigger, and outside-app
  concurrent re-adds cannot be guarded atomically with these APIs.
  `test/movie_watchlist_reconciliation_2026_test.dart` covers failure/retry,
  auth race, re-add, profile change and native completion; worker's combined
  movie suites **49/49 passing**, focused analyzer clean.

### Follow-on Spotlight identity standardization — October 25

**Final integrated verification (October 25):** after the screenshot-driven
player alignment/safe-area and IMDb provenance correction, the complete
19-file playback/loader/glass/watchlist/native-TV recovery regression command
finished **199/199 passing**. `flutter analyze` across 13 changed player,
loader, reconciliation and test inputs found **no issues**; the independent
navigation/discovery/Cloud/Settings test command passed **91/91**. The shared
Spotlight identity and new opt-in Skia/Impeller player glass preserve live
Flutter-backdrop sampling and keyboard/D-pad controls. A currently running
macOS debug app was detected, but a fresh *post-change live-movie playback*
visual capture/interaction was not completed; only macOS and Chrome were
available as Flutter devices, no Android TV/tvOS hardware. All mutations stay
uncommitted in the pre-existing dirty tree; release signoff is not claimed.

The user rejected image/mockup approximations and specifically requested
using the *actual Home Spotlight code* for both the loading overlay and the
player. The live changes now share one `SpotlightMediaIdentity` component
(`lib/widgets/home/spotlight_media_identity.dart`) with Home's `OpticalLogo`
dimensions, reserved artwork placement and text fallback. The order is always
dominant logo/title → **one metadata line containing IMDb and episode** plus
other sourced facts → synopsis. The episode is not a disconnected label over
the logo; no unsupported rating or episode description is fabricated. Narrow
screens wrap label groups without orphan separators.

**Real-device screenshot follow-up:** the 1649×922 macOS screenshot from the
user exposed an overlooked *geometry* mismatch despite prior test passes:
the 560px-wide player identity had been horizontally centered, putting the
logo around x≈545 instead of the detail page's x≈72. The production player
uses an explicit 72/42/24px wide/tablet/phone left gutter now. Its wordmark
gets a separate 1.5× optical scale on wide displays, while the episode/IMDb
metadata and synopsis retain their readable text scale; the block rises
30px above the dock. Source-unknown episode-guide scores are no longer
mislabelled IMDb. Existing media-provider and current-episode policy are
preserved. The 1649×922 geometry is asserted in tests; actual *new* macOS
rendering has not yet been visually rechecked.

The Marquee loader uses this identity followed by the *existing* four-stage
progress rail, status narration, provider badge and Cancel behavior;
`PlayLoaderArt` now carries the sourced description. The player replaces its
previous small title/logo presentation with the shared optical identity at
the lower left while preserving subtitles, timeline, PiP, live channels and
native focus. It also uses Home's selected metadata presentation policy in
addition to Stremio `/meta` for logos and synopses, with current-title/profile
generation guards. Top/middle duplicate VOD information is suppressed only
where the Spotlight identity is displayed.

Automated validation completed: the shared hierarchy/IMDb/compact/reserved
artwork tests pass 4/4; loader-specific overlay suite passes 29/29 and
loader style 12/12; player Spotlight + media details passes 19/19 (including
long synopsis, 320dp portrait, short landscape, actual episode metadata,
profile/provider generation and metadata fallback). An additional single
integrated command ran all shared/loader/player tests plus Home–Explore and
Watch navigation regressions: **79/79 passed**, analyzer clean for all 11
Spotlight/loader/player/navigation source and test inputs. `git diff --check`
was clean on touched tracked files. Nothing in those automated proofs asserts
the network will return a particular logo or that the macOS/Android TV/tvOS
native video plane has been visually verified after the change. Physical
video/HDR/refraction inspection and actual playback-device signoff remain
release gates; no screenshot or image artifact is requested for this pass.

Integrated automated proof: native movie policy + original completion policy
24/24 passing; local watched/watchlist reconciliation with existing storage
34/34 passing; merged native/sync analyzer clean; navigation/discovery/Cloud/
Settings regression 78/78 passing. Player information/credits/shader/dock
and TV recovery regression **114/114 passing**, including live shader program
asset compilation. Analyzer clean for the player, glass, launcher, sync
services and new tests. The running macOS desktop app was detected, but its
screen was not capturable from this shell (`screencapture`: `could not create
image from display`); interactive movie HDR/video/refraction verification
has **not** been completed. Available iOS simulator images were shut down;
physical Android TV/tvOS devices were not available. Do not treat these
automated results as an end-to-end streaming/device release signoff.

## Product objective

Make the next action obvious: find a title, start watching, resume something, manage a download, browse cloud files, or change a setting. Reduce decisions and duplicate entry points while preserving deep links, profile permissions, established workflows, and TV remote control.

The page cohesion map is sound on visual architecture. Keep its four deliberate presentation systems:

1. **Glass:** Home, title detail, downloaded library, transfer queue, catalog and collections.
2. **Cloud:** the six provider file browsers with CloudScaffold.
3. **TV:** ten-foot browsing and player interfaces designed for the D-pad.
4. **Settings:** its own grouped, searchable configuration interface.

The priority is **information architecture, behavior, and consistency within each family**, not turning every screen into the same visual template. Keep the browse-title detail and the Stremio-TV channel tune-in detail separate.

## Verified as-built state (corrects the earlier draft)

| Surface | Live state | UX implication |
|---|---|---|
| Home / Search / Discover | Three routes use modes of SearchScreen; wide layouts expose Search, while phones reach search from Home | Clarify browse vs targeted search before hiding any entry |
| Watch | Hub groups IPTV, YouTube, Nextup TV and Stremio TV, with Reels under Clips; Reels also remains independently pinnable in phone and TV/desktop navigation | Preserve independent Reels pins and the shared Clips entry |
| Navigation customization | Classic phone navigation has three selectable middle slots plus the fixed shell controls; the sidebar editor manages TV/desktop ordering | Do not confuse the seven default *candidates* with seven visible phone items or apply sidebar edit affordances to phone ordering |
| Cloud | Only Cloud appears in the visible nav; six providers are pushed from that hub | Existing draft's proposal to remove six top-level provider tabs is **already implemented** |
| Downloads | Downloaded library and transfer manager are distinct user jobs within the glass family | Preserve the successful one-scroll transfer manager, with straightforward access from title detail |
| Settings | Eleven named categories and SettingsSearchPage already exist; older long-form layout also remains | Improve deep-link precision and platform-specific navigation explanations, not generic grouping from scratch |
| Legacy indices | MainTab values are still stable numeric route identities, including deprecated 0 and feed/provider indices | Deleting or renumbering indices now would break callers and migrations |

Evidence: lib/main.dart:3053-3167, 3260-3294, 3503-3569; lib/screens/watch_hub_screen.dart:33-66; lib/screens/cloud_screen.dart:39-84; lib/models/sidebar_configuration.dart:31-98; lib/screens/settings_screen.dart:7473-7584.

## P0 — Repair the current Watch migration before release

These findings come from live code inspection. Runtime regression tests are required before declaring the existing Watch changes complete.

1. **Reels reachability and playback.** WatchHubScreen currently lists four feeds and explicitly excludes Reels (lines 33-66), but all three visible-nav lists in main.dart omit its old tab (lines 3089-3153). MainPageBridge documents five feed keys, while main.dart:_openFeed handles only four. Put Reels in Watch (recommended), with its own distinct Clips grouping, and make ReelsScreen active when its pushed route is foregrounded. Preserve its pause/resume behavior and a visible return path.
2. **IPTV startup deep link.** The IPTV launch path sets MainTab.iptv as initial tab (main.dart:1331-1333). Later policy and integration reconciliation fall back to Home if a selected tab is absent from visible navigation (lines 1876-1890, 2965-2990); IPTV is now absent by design. Introduce a dedicated authorized startup route/intent or exempt the pending channel while resolving it. Test both possible async completion orders and cancellation.
3. **Saved navigation migration.** The prior sidebar catalog stored IDs for the five feeds. The new sidebar catalog drops those IDs, and SidebarConfiguration.tryDecode rejects unknown old IDs (sidebar_configuration.dart:140-190). A saved configuration can fall back to defaults and lose customized order, labels and hidden states. Add an explicit versioned migration mapping legacy feed IDs to Watch, preserving all surviving choices and deduplicating Watch. Migrate stored classic-phone middle-slot picks (old indices 3, 9, 13, 14, 20) to Watch (21), preserving the chosen slot count and avoiding duplicates; verify profile backup/restore.
4. **Permission-aware hub.** main.dart:_openFeed currently has no explicit per-feed ProfileFeature policy gate, while the hub always renders its four entries. Show only permitted feeds, check permission again at route entry, and make a useful empty state when a profile has none. Authorized autoplay and links must remain possible where the policy permits.
5. **Caller/Back semantics.** Opening Watch from a tab, Home shortcut, playlist or notification should return to that origin when Back/Escape/Menu is pressed. Verify D-pad initial focus and restored focus, dialog dismissal, player launch and nested detail routes. The TV shell still marks tab 21 as active while the feed screens register content focus under their old indices (3, 9, 13, 14); route-level focus ownership needs an explicit handoff. A generic route pop cannot substitute for a screen's own Back handler.
6. **Legacy feed destinations.** MainPageBridge.switchTab validates against visible tab indices, so older callers selecting 3, 9, 13, 14 or 20 are now rejected. Preserve these stable identities as dispatch aliases into Watch feeds (while respecting permissions) and migrate source-origin metadata that points back to a hidden tab.

Exit gate: all five feed intents work on phone, desktop, Android TV and tvOS; permitted startup IPTV plays or cancels correctly; restricted profiles cannot enter prohibited feeds; saved nav preferences survive an update; TV focus returns to the correct tile; no orphaned feed remains.

## Target information architecture (design hypothesis)

Organize navigation around what the person wants to do rather than the underlying services.

| User intent | Primary destination | Nested behavior |
|---|---|---|
| Resume / find recommendations | **Home** | Continue Watching, collections, curated rails, direct title detail |
| Find a specific title | **Search** action on Home; dedicated entry on wide screens/TV | Search modes Catalog / Keyword / Lists stay intact, with existing restrictions |
| Explore a catalog or source | **Explore** inside Home, opening the current Discover grid | Source selection, credits browsing and filters preserve state |
| Put on a channel or feed | **Watch** | Live/IPTV, YouTube, Nextup TV, Stremio TV; Reels as Clips |
| Find a saved or downloaded item | **Library** (candidate hub, validate before building) | On-device downloads, transfer queue, Cloud providers, playlists/saved collections |
| Configure services | **Settings** | Existing categories and search; Addons reachable in context through Connections/Search |
| See upcoming tracked releases | Home shortcut + Calendar in an appropriate secondary menu | Preserve current Trakt/Simkl calendar behavior |

**Proposed navigation by form factor:** phone classic bar: Home, Watch, Library, More (Search remains a prominent Home action); desktop/tablet rail: Home, Search, Watch, Library, Settings; TV sidebar: Home, Search, Watch, Library, Settings, with optional calendar/addons shortcuts. Treat these as targets to validate, not as an immediate replacement for user-customized navigation. Retain a configurable shortcut path for frequent Downloads, Cloud and Calendar users; do not add a fifth tap to a common task just to reduce icons.

The candidate Library grouping must be validated in usability sessions. Device downloads, transfers and provider files have different state and urgency; if testing shows a combined hub slows common tasks, keep separate direct destinations with consistent naming and hierarchy.

## Implementation phases

### Phase 0 — Navigation stabilization (P0, required first)

- Implement the five P0 repairs above in the existing Watch/route code.
- Introduce tests that navigate by visible controls, not just assert enums or sidebar counts.
- Use a shared destination descriptor for feed key, title, icon, enabled state and profile feature, consumed by hub and route handler. Do not maintain two independent feed inventories.
- Add an explicit route activity signal for the Reels player so clips play when visible and suspend beneath other routes.

Owner files: lib/screens/watch_hub_screen.dart; lib/main.dart; lib/services/main_page_bridge.dart; lib/models/sidebar_configuration.dart; corresponding navigation/profile/reels tests.

### Phase 1 — Cloud workflow polish (P1, low to medium risk)

Cloud is already the single top-level door. Polish its behavior:

- Rename provider controls from ambiguous **Hide provider tab** to an action matching current semantics (**Show in Cloud** / **Hide from Cloud**), and provide recovery directly from Connections settings. Today the old option also removes a provider from the Cloud hub.
- Provide clear Cloud empty states: no providers configured, all hidden, credentials expired, no files, loading or error; offer **Set up a provider** where authorized.
- Put an explicit Back to Cloud action in each pushed provider root. Real-Debrid, Torbox and AllDebrid roots presently have no app bar; PikPak, Premiumize and WebDAV have an explicit Back. Make D-pad, Escape and hardware Back agree.
- Keep Cloud Files permission separate from provider API permission: a restricted profile must not browse another person's cloud file history while still being able to play through permitted provider operations.
- Review the old return-to-search path using MainTab.legacyTorrentSearch (0) in RD, Torbox, PikPak and Premiumize. Redirect to the real origin, never to the inert Home slot.

Owner files: lib/screens/cloud_screen.dart; cloud provider screen roots; provider Settings pages; main.dart:openCloudProvider; route/back tests.

### Phase 2 — One coherent discovery journey (P1/P2, medium risk)

- Preserve three *jobs* but reduce duplicate top-level navigation: Home = recommendations/resume; Search = explicit query; Explore = a browse mode accessed from Home.
- Inventory the modes and flows of SearchScreen before moving them: catalog/keyword/lists search, source dropdown, Continue Watching, credits, filters, focused title state, source intent, keyboard/D-pad input and profile restrictions.
- Add an **Explore catalogs** action to Home, opening the current Discover experience as a child route/mode; preserve selected source, scroll position and return focus when navigating to a title and back.
- Keep the TV dedicated Search prompt and wide-layout Search shortcut; phone continues with Home's search action. Hide the separate Discover nav entry only after parity and return behavior pass.
- Do not rewrite the 20k-plus-line SearchScreen in one pass. Extract navigation intent/state progressively behind tests.

Owner files: lib/screens/search_screen.dart; lib/main.dart; lib/widgets/search_source_dropdown.dart; Home cards and sidebar configuration.

### Phase 3 — Library hub pilot (P2, medium risk; evidence-gated)

- Prototype one Library entry with two obvious first-level choices: **On device** (downloaded titles and transfer queue) and **Cloud** (existing hub). Include Playlists/Collections only if the inventory confirms they fit users' expectations.
- Keep direct entry from title detail to current download/task and deep links straight to a specific provider, folder or title.
- Try phone and D-pad prototypes with existing users. Compare task completion and steps to current Downloads + Cloud, including offline mode. Ship only if the hub improves access; otherwise use the validated naming/shortcuts without extra hierarchy.
- Preserve user-selected navigation shortcuts and favorite destination; migrate only defaults that have not been customized.

Potential owners: new Library hub; lib/main.dart; lib/screens/downloads_screen.dart; lib/screens/download_manager_screen.dart; lib/screens/cloud_screen.dart; navigation prefs.

### Phase 4 — Close measured browser interaction gaps (P2, conditional)

- Start from the shared components that **already exist**: CloudFileRow, CloudSegmentedTabs, CloudRowSkeletonList and CloudScaffold. All six providers already consume CloudFileRow, with shared primary action/menu/focus handling and dedicated widget tests.
- Audit concrete remaining differences in folder Back/focus, selection, empty/error/retry behavior, action labeling and status messages across providers. Capture only reproducible inconsistencies that are unintended.
- Promote proven shared interactions into existing widgets or small explicit capability adapters. Leave each provider's distinct file and transfer semantics intact.
- If a measured gap warrants a shared state contract, migrate one provider first and compare equivalent fixture-driven scenarios. A broad CloudFilesScaffold rewrite is **not justified by the present map alone**.

Owners: lib/widgets/cloud/ and whichever provider screen shows the proven gap. Reuse test/cloud_file_row_test.dart and add focused provider navigation coverage only for changed behaviors.

### Phase 5 — Settings clarity in context (P2, low risk)

- Keep the existing **11 categories** and rich Settings search. Audit settings that are hard to discover, duplicate labels and settings entered from different locations.
- Make search results focus/highlight the actual matching control; currently leaf search opens its parent page without precise highlighting.
- Explain platform scope accurately: sidebar ordering/labels are shared by desktop and TV; phone classic navigation uses separate three-slot picks, and its visibility rules differ. Display controls appropriate to the active device.
- Review the navigation style editor, which currently persists desktop and phone styles together; make cross-device effects explicit or separate the controls.
- Provide short contextual links: Watch empty state → connections, Cloud empty state → providers, no search sources → Addons, no tracks → tracker setup.
- Retain the existing Spotlight categories and legacy settings layout until equivalent behaviors are verified.

Owners: lib/screens/settings_screen.dart; lib/screens/settings/sidebar_customization_page.dart; Settings search and navigation tests.

### Phase 6 — Retire legacy route plumbing safely (P3, last)

- Add a central typed destination registry (stable string identity, label, feature gate, allowed platforms, route presentation and return behavior). Keep an adapter from legacy MainTab integers for existing callers and persisted data.
- Trace every old destination use: default tabs, TV start channel, stored phone/sidebar picks, remote commands, deep links, third-party intents and backups. Redirect supported requests to the correct new hub or child route.
- Remove index-0 fallback and obsolete source-only widgets only after reference searches and navigation tests prove they are unused. Avoid renumbering existing MainTab constants.
- Keep Stremio-TV's channel tune-in detail and TV-specific/player UIs.

## Release and validation contract

| Gate | Must be demonstrated |
|---|---|
| Reachability | Every surfaced Watch feed/provider/setting opens by tapping, keyboard and D-pad, including Reels |
| Profile protection | Admin/member/child and custom feature policies control both tiles and direct routes |
| Lifecycle | Back/Escape/Menu restores correct parent and focus; re-entering feed retains or resets state as specified |
| Deep links | IPTV channel start, cloud folder, download detail, shortcuts and remote commands work after migration |
| Persistence | Existing phone picks and versioned sidebar customizations survive upgrade, profile change and backup/restore |
| Visual | Phone portrait/landscape, tablet/desktop rail and pill, Android TV, tvOS; safe areas and overlay controls intact |
| Performance | No extra Home/TV provider loading just to render a hub; no duplicate screen stacks on rapid selections |
| Accessibility | Descriptive tile labels, visible focus, reachable exit action, predictable Back, readable empty/error text |

Use existing tests as anchors: test/sidebar_configuration_test.dart; test/reels_test.dart; test/sidebar_profile_navigation_test.dart; test/tv_sidebar_pill_test.dart; test/desktop_pill_nav_test.dart; test/cloud_file_row_test.dart; test/settings_search_grouping_test.dart; test/settings_single_focus_test.dart; test/discover_shelf_test.dart; test/iptv_source_search_test.dart. Add focused integration tests for actual route transitions and startup intents. Static analysis alone is insufficient to mark a navigation phase done.

## Rollout order and decision gates

| Order | Work | Value | Effort/risk | Go/no-go |
|---|---|---|---|---|
| Now | Phase 0: correct Watch regressions | Restore lost functionality and safe routing | Medium / high urgency | Required before this navigation change ships |
| Next | Phase 1: Cloud copy, empty state, Back and origin | Fewer dead ends | Small–medium / low | Every provider route passes phone/TV Back |
| Then | Phase 2: Home + Explore + Search | Clearer discovery model | Medium–large / medium | Task parity + focus/scroll restored |
| Pilot | Phase 3: Library hypothesis | Fewer top-level decisions | Medium / conditional | Demonstrably fewer steps for representative users |
| Conditional | Phase 4: measured provider behavior gaps | Repeatable browser interactions | Small–medium / conditional | A real gap exists and shared components cover it |
| Parallel | Phase 5: settings clarity | Better findability and control | Small–medium / low | Search lands at the right control |
| Last | Phase 6: legacy cleanup | Lower maintenance overhead | Medium / migration-sensitive | Zero obsolete callers and backward-compatible data |

### Suggested usability measures

Record a baseline first, then compare: clicks/presses to resume a title, open a particular feed, find a download, open a cloud provider, locate subtitles settings and return to the prior screen; task completion, wrong-destination taps, and failed/ambiguous Back navigation. Target no regression in critical workflows and measurable improvement in discovery and settings tasks. A smaller nav count alone is not a success metric.

## Intentional boundaries

Do not collapse Glass/Cloud/TV/Settings into one visual style. Do not combine catalog browse detail with channel tune-in. Do not flatten the download manager back into tabs or rewrite its working glass scroll. Do not delete the legacy numeric tab IDs during feature migration. Do not hide direct routes that users need for deep links, startup playback or favorite shortcuts.
