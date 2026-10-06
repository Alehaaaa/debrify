import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/stremio_addon.dart';
import '../services/debrify_image_cache.dart';
import '../services/main_page_bridge.dart';
import '../services/offline_title_store.dart';
import '../services/profiles/profile_runtime.dart';
import '../services/reels_feed.dart';
import '../services/storage_service.dart';
import '../services/simkl/simkl_service.dart';
import '../services/trakt/trakt_service.dart';
import '../services/youtube_service.dart';
import '../utils/platform_util.dart';
import '../utils/tv_keys.dart';
import '../widgets/hero_trailer_backdrop.dart';
import '../widgets/trailer_engine.dart';

enum _ClipState { idle, resolving, ready, failed }

/// A reel in the feed: the title, its clip, and that clip's stream once
/// it has been resolved (only ever for the reel on screen and the next one).
class _Reel {
  _Reel(this.title);

  final ReelTitle title;
  YoutubeResolvedStreams? streams;
  _ClipState state = _ClipState.idle;
  int revision = 0;
  Duration position = Duration.zero;
  DateTime? leftAt;

  StremioMeta get item => title.item;
}

class _ReelsSession {
  const _ReelsSession({
    required this.scope,
    required this.feed,
    required this.reels,
    required this.index,
  });

  final Object? scope;
  final ReelsFeed feed;
  final List<_Reel> reels;
  final int index;
}

/// Reels: a vertical feed of official scene clips, one title per screen.
///
/// Swipe up for the next title, down for the previous; pulling down on the
/// first one swaps it for a fresh title. Each reel plays its clip full-bleed
/// with the title's logo, the clip's name, genres and an expandable
/// description at the bottom-left, and on the right a mute toggle and an Add
/// to My Watchlist button. Tapping the title opens its full page (and Back
/// returns here).
///
/// Built to scroll fast on few requests: titles arrive with everything a
/// reel shows already known (see [ReelsFeed] — one TMDB request per title),
/// so a reel paints its backdrop the moment it's on screen. The clip's stream
/// is resolved for the reel on screen and a bounded look-ahead window.
/// Only the visible high-resolution reel owns the decoder.
class ReelsScreen extends StatefulWidget {
  final bool isTelevision;

  /// The shell overlays its navigation capsule in the lower-right corner.
  final bool floatingNav;

  /// Test seams. Production uses the TMDB clip feed and the app's YouTube
  /// stream resolver.
  @visibleForTesting
  final ReelsFeed? feed;
  @visibleForTesting
  final Future<YoutubeResolvedStreams?> Function(String clipKey)? resolver;

  /// Test seam: what plays behind a reel. Production uses
  /// [HeroTrailerBackdrop].
  @visibleForTesting
  final Widget Function(ReelPlayback playback)? playerBuilder;

  const ReelsScreen({
    super.key,
    this.isTelevision = false,
    this.floatingNav = false,
    this.feed,
    this.resolver,
    this.playerBuilder,
  });

  @override
  State<ReelsScreen> createState() => _ReelsScreenState();
}

/// What one reel's player is asked to do. [streams] is null until the clip
/// has been resolved.
class ReelPlayback {
  const ReelPlayback({
    required this.item,
    required this.streams,
    required this.active,
    required this.volume,
    this.paused = false,
    this.prewarm = false,
    this.initialPosition,
    this.onPosition,
    this.failed = false,
    this.onPlaybackFailed,
  });

  final StremioMeta item;
  final YoutubeResolvedStreams? streams;
  final bool active;
  final bool failed;
  final VoidCallback? onPlaybackFailed;

  /// Keep the current and next iOS native players prepared.
  final bool prewarm;
  final double volume;

  /// Tapped to pause: hold the frame, keep the player.
  final bool paused;
  final Duration? initialPosition;
  final ValueChanged<Duration>? onPosition;
}

class _ReelsScreenState extends State<ReelsScreen> {
  /// Sound on or off, for the whole feed — kept for the app session so the
  /// choice survives leaving the tab.
  static bool _muted = false;
  static _ReelsSession? _session;

  /// Confirmed titles kept queued past the one on screen, so a fling never
  /// runs into the end of the feed. Each costs one TMDB request.
  static const int _ahead = 6;

  /// Reels past the one on screen whose clip is resolved ahead, so swiping
  /// through several in a row lands on clips that start straight away. Each
  /// costs one YouTube lookup.
  static const int _streamsAhead = 3;

  /// How far the first reel must be pulled down to refresh it.
  static const double _refreshPull = 90;

  late final ReelsFeed _feed;
  // The feed owns its index. Restoring an unrelated PageStorage offset would
  // put the visible page and the selected player out of sync on tab re-entry.
  late final PageController _pages;
  final FocusNode _focus = FocusNode(debugLabel: 'reels');
  final Object? _scope = ProfileRuntime.scope.value;
  late final List<_Reel> _reels;
  final Set<String> _postersPrepared = {};
  final Map<String, bool> _inWatchlist = {};

  int _index = 0;
  bool _filling = false;
  bool _exhausted = false;
  bool _refreshing = false;
  double _pull = 0;
  bool _refreshArmed = false;
  int? _dragPage;
  bool _movingByKey = false;
  late final _ReelPagePhysics _physics = _ReelPagePhysics(
    anchorPage: () => _dragPage ?? _index,
    parent: const BouncingScrollPhysics(),
  );

  /// The reel on screen is paused (a tap on the video). A new reel always
  /// starts playing.
  bool _paused = false;

  bool get _current => mounted && ProfileRuntime.scope.value == _scope;

  @override
  void initState() {
    super.initState();
    final saved = widget.feed == null && _session?.scope == _scope
        ? _session
        : null;
    _feed = saved?.feed ?? widget.feed ?? ReelsFeed();
    _reels = saved?.reels ?? [];
    _index = saved?.index ?? 0;
    _pages = PageController(initialPage: _index, keepPage: false);
    // Returning from the detail page restores the frame without resuming audio
    // or motion behind the user.
    _paused = saved != null;
    if (!_feed.available) {
      _exhausted = true;
      return;
    }
    unawaited(_fill());
  }

  @override
  void dispose() {
    if (widget.feed == null) {
      _session = _ReelsSession(
        scope: _scope,
        feed: _feed,
        reels: _reels,
        index: _index,
      );
    }
    _pages.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ── feed ───────────────────────────────────────────────────────────────

  /// Keep [_ahead] titles queued past the one on screen.
  Future<void> _fill() async {
    if (_filling || _exhausted) return;
    _filling = true;
    try {
      while (_current && !_exhausted) {
        final need = _index + 1 + _ahead - _reels.length;
        if (need <= 0) break;
        // Publish the first title immediately; don't make its playback wait
        // for the entire look-ahead batch to finish fetching metadata.
        final titles = await _feed.take(
          _reels.isEmpty ? 1 : need,
          allowRepeat: true,
        );
        if (!_current) return;
        final unseen = await Future.wait([
          for (final title in titles)
            _isWatched(title.item).then((watched) => watched ? null : title),
        ]);
        if (!_current) return;
        final playable = [for (final title in unseen) ?title];
        setState(() {
          _reels.addAll(playable.map(_Reel.new));
          if (titles.isEmpty) {
            _exhausted = _feed.lastRequestFailed || _feed.exhausted;
          }
        });
        for (final title in playable) {
          unawaited(_loadWatchlist(title.item));
        }
        _prepare();
        if (titles.isEmpty && !_exhausted) {
          // Yield between bounded search windows without declaring a sparse
          // page to be the end of the catalog.
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    } finally {
      _filling = false;
    }
  }

  void _retryFeed() {
    if (!_current || _filling) return;
    setState(() => _exhausted = false);
    unawaited(_fill());
  }

  /// Independent requests: a slow lookup for a reel already swiped past
  /// must never hold up the current reel or the rest of the look-ahead window.
  void _prepare() {
    for (var i = _index; i <= _index + _streamsAhead; i++) {
      if (i < _reels.length) {
        final item = _reels[i].item;
        final still = item.background ?? item.poster;
        if (still != null && still.isNotEmpty && _postersPrepared.add(still)) {
          unawaited(
            precacheImage(
              ResizeImage.resizeIfNeeded(
                1920,
                null,
                CachedNetworkImageProvider(
                  still,
                  cacheManager: DebrifyImageCache.manager,
                ),
              ),
              context,
              onError: (_, _) {},
            ),
          );
        }
      }
      unawaited(_resolve(i));
    }
  }

  Future<void> _resolve(int index) async {
    if (index < 0 || index >= _reels.length) return;
    final reel = _reels[index];
    if (reel.state != _ClipState.idle) return;
    reel.state = _ClipState.resolving;
    final revision = reel.revision;
    YoutubeResolvedStreams? streams;
    try {
      streams =
          await (widget.resolver?.call(reel.title.clipKey) ??
                  YoutubeService.resolvePreviewStreams(
                    reel.title.clipKey,
                    // Full-bleed on a phone: a portrait crop of a 16:9 frame wants
                    // more lines than a card preview.
                    maxHeightOverride: 1080,
                    preferMuxed: false,
                    preferVp9: false,
                  ))
              .timeout(const Duration(seconds: 30));
    } catch (_) {
      streams = null;
    }
    if (!_current || !_reels.contains(reel) || reel.revision != revision) {
      return;
    }
    setState(() {
      if (streams != null && streams.hasPlayable) {
        reel.streams = streams;
        reel.state = _ClipState.ready;
      } else {
        reel.state = _ClipState.failed;
        _feed.excludeClip(reel.title.clipKey);
      }
    });
    _discardFailedAhead();
  }

  /// Loading can change a clip, never the page. In particular, failed clips
  /// stay in place for retry. Future failures are discarded without navigation.
  void _retry(_Reel reel) {
    if (!_current || reel.state != _ClipState.failed) return;
    final index = _reels.indexOf(reel);
    if (index < 0) return;
    YoutubeService.invalidateStreams(reel.title.clipKey);
    _feed.allowClip(reel.title.clipKey);
    setState(() {
      reel.revision++;
      reel.streams = null;
      reel.state = _ClipState.idle;
      if (index == _index) _paused = false;
    });
    unawaited(_resolve(index));
  }

  /// Pull-down on the first reel: swap it for a fresh title.
  Future<void> _refreshFirst() async {
    if (_refreshing || !_feed.available) return;
    setState(() => _refreshing = true);
    HapticFeedback.mediumImpact();
    try {
      final titles = await _feed.take(1, allowRepeat: true);
      if (!_current || titles.isEmpty) return;
      setState(() {
        final reel = _Reel(titles.first);
        if (_reels.isEmpty) {
          _reels.add(reel);
        } else {
          _reels[0] = reel;
        }
      });
      unawaited(_loadWatchlist(titles.first.item));
      if (_index == 0) _prepare();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _onPage(int index) {
    if (index == _index) return;
    final previous = _reels[_index];
    previous.leftAt = DateTime.now();
    final next = _reels[index];
    final leftAt = next.leftAt;
    if (leftAt != null &&
        DateTime.now().difference(leftAt) > const Duration(seconds: 5)) {
      next.position = Duration.zero;
    }
    next.leftAt = null;
    setState(() {
      _index = index;
      _paused = false;
    });
    HapticFeedback.selectionClick();
    unawaited(_fill());
    _prepare();
  }

  void _playbackFailed(_Reel reel, int revision) {
    if (!_current ||
        reel.revision != revision ||
        reel.state != _ClipState.ready ||
        !_reels.contains(reel)) {
      return;
    }
    setState(() {
      reel.state = _ClipState.failed;
      reel.streams = null;
      _feed.excludeClip(reel.title.clipKey);
    });
    _discardFailedAhead();
  }

  /// Remove only failed future pages. Never rebase the visible item or a
  /// live gesture; postponed removals run after scrolling settles.
  void _discardFailedAhead() {
    if (!_current ||
        _dragPage != null ||
        (_pages.hasClients && _pages.position.isScrollingNotifier.value)) {
      return;
    }
    final failed = _reels
        .skip(_index + 1)
        .where((reel) => reel.state == _ClipState.failed)
        .toList();
    if (failed.isEmpty) return;
    setState(() => _reels.removeWhere(failed.contains));
    unawaited(_fill());
    _prepare();
  }

  void _togglePause() {
    if (_reels[_index].state != _ClipState.ready) return;
    HapticFeedback.selectionClick();
    setState(() => _paused = !_paused);
  }

  /// DPAD / keyboard: up/down move through the feed, Space pauses the clip,
  /// and OK opens the title.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _go(_index + 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (_index > 0) {
        _go(_index - 1);
      } else {
        unawaited(_refreshFirst());
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space) {
      _togglePause();
      return KeyEventResult.handled;
    }
    if (isActivateKey(key)) {
      if (_index < _reels.length) _open(_reels[_index].item);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _go(int index) {
    if (_movingByKey ||
        index < 0 ||
        index >= _reels.length ||
        !_pages.hasClients) {
      return;
    }
    _movingByKey = true;
    unawaited(
      _pages
          .animateToPage(
            index,
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() => _movingByKey = false),
    );
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0) return false;
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _dragPage = (n.metrics.pixels / n.metrics.viewportDimension)
          .round()
          .clamp(0, _reels.length - 1);
      _refreshArmed = false;
    }
    if (n is ScrollEndNotification) {
      _dragPage = null;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _discardFailedAhead(),
      );
      if (_refreshArmed && _index == 0) unawaited(_refreshFirst());
      _refreshArmed = false;
      if (_pull != 0) setState(() => _pull = 0);
      return false;
    }
    if (_dragPage != 0) return false;
    // Pulled past the top of the first reel (the bounce shows it as negative
    // offset): follow the finger, and refresh once it lets go far enough.
    if (n is ScrollUpdateNotification) {
      final pull = (-n.metrics.pixels).clamp(0.0, double.infinity);
      if (pull != _pull) setState(() => _pull = pull);
      if (n.dragDetails != null && _pull >= _refreshPull) _refreshArmed = true;
    } else if (n is OverscrollNotification &&
        n.overscroll < 0 &&
        n.dragDetails != null) {
      // Clamping physics report the pull as overscroll instead.
      setState(() => _pull = (_pull - n.overscroll).clamp(0.0, 200.0));
      if (_pull >= _refreshPull) _refreshArmed = true;
    }
    return false;
  }

  // ── actions ────────────────────────────────────────────────────────────

  String _watchKey(StremioMeta item) => '${item.type}:${item.id}';

  Future<StremioMeta> _watchlistItem(StremioMeta item) async =>
      item.sourceAddon != null
      ? item
      : StorageService.withMyWatchlistSource(
          item,
          await OfflineTitleStore.cinemetaAddon(),
        );

  Future<void> _loadWatchlist(StremioMeta item) async {
    try {
      final saved = await StorageService.isInMyWatchlist(
        await _watchlistItem(item),
      );
      if (_current) setState(() => _inWatchlist[_watchKey(item)] = saved);
    } catch (_) {}
  }

  Future<void> _toggleWatchlist(StremioMeta item) async {
    final key = _watchKey(item);
    final next = !(_inWatchlist[key] ?? false);
    setState(() => _inWatchlist[key] = next);
    HapticFeedback.mediumImpact();
    try {
      await StorageService.setMyWatchlistItem(await _watchlistItem(item), next);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              next ? 'Added to My Watchlist' : 'Removed from My Watchlist',
            ),
          ),
        );
    } catch (_) {
      if (!mounted) return;
      setState(() => _inWatchlist[key] = !next);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn\'t update My Watchlist')),
      );
    }
  }

  /// A double tap is intentionally one-way: it is a quick "save this" action,
  /// so it must never remove something the user had already saved.
  void _addToWatchlist(StremioMeta item) {
    if (_inWatchlist[_watchKey(item)] ?? false) return;
    unawaited(_toggleWatchlist(item));
  }

  /// Do not surface a title already completed by either connected tracker.
  /// Both services return null for disconnected/temporarily unavailable
  /// accounts, which deliberately leaves the candidate in the feed.
  Future<bool> _isWatched(StremioMeta item) async {
    final imdb = item.effectiveImdbId;
    if (imdb == null) return false;
    try {
      final statuses = await Future.wait([
        TraktService.instance.fetchTitleStatus(imdb, item.type),
        SimklService.instance.fetchTitleStatus(imdb, contentType: item.type),
      ]);
      final trakt = statuses[0] as TraktTitleStatus?;
      final simkl = statuses[1] as SimklTitleStatus?;
      return trakt?.titleWatched == true || simkl?.currentStatus == 'completed';
    } catch (_) {
      return false;
    }
  }

  void _toggleMute() {
    HapticFeedback.selectionClick();
    setState(() => _muted = !_muted);
  }

  /// The title's full page, opened by the Home board (which owns the detail
  /// page and its Play / Sources machinery); closing it comes back here.
  void _open(StremioMeta item) {
    final imdb = item.effectiveImdbId;
    if (imdb == null) return;
    // Preserve the current frame and the queue while Home owns the detail
    // route. The recreated Reels page restores this session paused.
    setState(() => _paused = true);
    _session = _ReelsSession(
      scope: _scope,
      feed: _feed,
      reels: _reels,
      index: _index,
    );
    MainPageBridge.pendingCatalogDetailOpen = {
      'imdbId': imdb,
      'type': item.type,
      'title': item.name,
      'year': int.tryParse(item.year?.split(RegExp(r'\D')).first ?? ''),
      'poster': item.poster,
      'originTab': MainTab.reels,
    };
    MainPageBridge.switchTab?.call(MainTab.home);
  }

  // ── build ──────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final Widget body;
    if (_reels.isEmpty) {
      body = Center(
        child: _exhausted
            ? _EmptyReels(
                needsTmdb: !_feed.available,
                connectionFailed: _feed.lastRequestFailed,
                onRetry: _feed.available ? _retryFeed : null,
              )
            : const CircularProgressIndicator(color: Colors.white),
      );
    } else {
      body = NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: PageView.builder(
          controller: _pages,
          // Upcoming URLs resolve ahead; keep the high-resolution decoder
          // exclusive to the visible page on platforms with one output slot.
          allowImplicitScrolling: false,
          scrollDirection: Axis.vertical,
          // The bounce is what lets the first reel be pulled down.
          // Use our single-gesture snapper, rather than adding PageView's own
          // ballistic physics on top of it.
          pageSnapping: false,
          physics: _physics,
          onPageChanged: _onPage,
          itemCount: _reels.length,
          itemBuilder: (context, i) {
            final reel = _reels[i];
            final revision = reel.revision;
            return _ReelPage(
              key: ValueKey('$i:${_watchKey(reel.item)}'),
              reel: reel,
              active: i == _index,
              // AVPlayer can keep the current clip and the next one prepared
              // together, so an iOS swipe has a frame ready at the page edge.
              // Desktop uses one media_kit output and keeps the next URL and
              // poster warm instead; attempting a second decoder would stall
              // both during the handoff.
              prewarm: PlatformUtil.isIosMobile && i == _index + 1,
              onPlaybackFailed: () => _playbackFailed(reel, revision),
              onRetry: () => _retry(reel),
              floatingNav: widget.floatingNav,
              paused: i == _index && _paused,
              onTogglePause: _togglePause,
              muted: _muted,
              inWatchlist: _inWatchlist[_watchKey(reel.item)] ?? false,
              onMute: _toggleMute,
              onWatchlist: () => _toggleWatchlist(reel.item),
              onAddToWatchlist: () => _addToWatchlist(reel.item),
              onOpen: () => _open(reel.item),
              onPosition: (position) => reel.position = position,
              playerBuilder: widget.playerBuilder,
            );
          },
        ),
      );
    }
    final pull = (_pull / _refreshPull).clamp(0.0, 1.0);
    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: ColoredBox(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            body,
            if (_reels.isNotEmpty &&
                _index == _reels.length - 1 &&
                _exhausted &&
                _feed.lastRequestFailed)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 16,
                left: 24,
                right: 24,
                child: FilledButton.icon(
                  onPressed: _retryFeed,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Retry loading more clips'),
                ),
              ),
            // Pull-to-refresh on the first reel.
            if (_refreshing || pull > 0)
              Positioned(
                top: MediaQuery.paddingOf(context).top + 16,
                left: 0,
                right: 0,
                child: Center(
                  child: _GlassCircle(
                    size: 40,
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.2,
                        color: Colors.white,
                        value: _refreshing ? null : pull,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Anchor every drag to the page where it began, including its momentum.
/// A long drag or a fast fling can reach the adjacent page, never cross a
/// second one. A new gesture immediately establishes a new anchor.
class _ReelPagePhysics extends PageScrollPhysics {
  const _ReelPagePhysics({required this.anchorPage, super.parent});

  final int Function() anchorPage;

  @override
  _ReelPagePhysics applyTo(ScrollPhysics? ancestor) =>
      _ReelPagePhysics(anchorPage: anchorPage, parent: buildParent(ancestor));

  @override
  double carriedMomentum(double existingVelocity) => 0;

  @override
  double applyBoundaryConditions(ScrollMetrics position, double value) {
    final height = position.viewportDimension;
    final lower = (anchorPage() - 1) * height;
    final upper = (anchorPage() + 1) * height;
    if (value < lower && value < position.pixels) {
      return value - (position.pixels < lower ? position.pixels : lower);
    }
    if (value > upper && value > position.pixels) {
      return value - (position.pixels > upper ? position.pixels : upper);
    }
    return super.applyBoundaryConditions(position, value);
  }

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    if (position.outOfRange || position.viewportDimension <= 0) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    var page = position.pixels / position.viewportDimension;
    if (velocity < -tolerance.velocity) page -= 0.5;
    if (velocity > tolerance.velocity) page += 0.5;
    final target =
        (page.round().clamp(anchorPage() - 1, anchorPage() + 1) *
                position.viewportDimension)
            .clamp(position.minScrollExtent, position.maxScrollExtent);
    if (target == position.pixels) return null;
    return ScrollSpringSimulation(
      spring,
      position.pixels,
      target,
      velocity.clamp(-2500.0, 2500.0),
      tolerance: tolerance,
    );
  }
}

/// One reel: the clip, the scrim, the identity bottom-left and the action
/// rail on the right.
class _ReelPage extends StatefulWidget {
  final _Reel reel;
  final bool active;
  final bool prewarm;
  final bool floatingNav;
  final VoidCallback onPlaybackFailed;
  final VoidCallback onRetry;
  final bool paused;
  final VoidCallback onTogglePause;
  final bool muted;
  final bool inWatchlist;
  final VoidCallback onMute;
  final VoidCallback onWatchlist;
  final VoidCallback onAddToWatchlist;
  final VoidCallback onOpen;
  final ValueChanged<Duration> onPosition;
  final Widget Function(ReelPlayback playback)? playerBuilder;

  const _ReelPage({
    super.key,
    required this.reel,
    required this.active,
    required this.prewarm,
    required this.floatingNav,
    required this.onPlaybackFailed,
    required this.onRetry,
    required this.paused,
    required this.onTogglePause,
    required this.muted,
    required this.inWatchlist,
    required this.onMute,
    required this.onWatchlist,
    required this.onAddToWatchlist,
    required this.onOpen,
    required this.onPosition,
    required this.playerBuilder,
  });

  @override
  State<_ReelPage> createState() => _ReelPageState();
}

class _ReelPageState extends State<_ReelPage>
    with AutomaticKeepAliveClientMixin {
  DateTime? _lastTapAt;
  Offset? _lastTapPosition;

  @override
  bool get wantKeepAlive => widget.prewarm;

  @override
  void didUpdateWidget(covariant _ReelPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.prewarm != oldWidget.prewarm) updateKeepAlive();
  }

  void _recognizeDoubleTap(PointerDownEvent event) {
    final now = DateTime.now();
    final previousAt = _lastTapAt;
    final previousPosition = _lastTapPosition;
    final isDoubleTap =
        previousAt != null &&
        previousPosition != null &&
        now.difference(previousAt) <= const Duration(milliseconds: 300) &&
        (event.position - previousPosition).distanceSquared <= 1600;
    _lastTapAt = isDoubleTap ? null : now;
    _lastTapPosition = isDoubleTap ? null : event.position;
    if (isDoubleTap) widget.onAddToWatchlist();
  }

  void _cancelTapIfDragged(PointerMoveEvent event) {
    final position = _lastTapPosition;
    if (position != null &&
        (event.position - position).distanceSquared > 1600) {
      _lastTapAt = null;
      _lastTapPosition = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final reel = widget.reel;
    final item = reel.item;
    final insets = MediaQuery.paddingOf(context);
    final playback = ReelPlayback(
      item: item,
      streams: reel.state == _ClipState.ready ? reel.streams : null,
      active: widget.active,
      volume: widget.muted ? 0 : 100,
      paused: widget.paused,
      prewarm: widget.prewarm && reel.state != _ClipState.failed,
      initialPosition: reel.position > Duration.zero ? reel.position : null,
      onPosition: widget.onPosition,
      failed: reel.state == _ClipState.failed,
      onPlaybackFailed: widget.onPlaybackFailed,
    );
    final genres = (item.genres ?? const <String>[]).take(4).join(' • ');
    final description = item.description?.trim();
    final clipName = reel.title.clipName;
    return Stack(
      fit: StackFit.expand,
      children: [
        // The video itself: a tap pauses or resumes it. The title, text and
        // buttons above keep their own taps.
        Listener(
          onPointerDown: _recognizeDoubleTap,
          onPointerMove: _cancelTapIfDragged,
          child: GestureDetector(
            // Keep the pause gesture immediate. GestureDetector delays onTap
            // while it waits to rule out a double tap, which made a normal
            // reel tap feel unresponsive. The Listener above recognizes the
            // second tap without joining this gesture arena.
            onTap: widget.onTogglePause,
            behavior: HitTestBehavior.opaque,
            child:
                widget.playerBuilder?.call(playback) ??
                ReelVideoSurface(
                  playback: playback,
                  onPlaybackFailed: widget.onPlaybackFailed,
                ),
          ),
        ),
        if (playback.failed && widget.active)
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Clip unavailable',
                  style: TextStyle(color: Colors.white),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: widget.onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Retry clip'),
                ),
              ],
            ),
          ),
        if (widget.paused)
          const IgnorePointer(
            child: Center(
              child: _GlassCircle(
                size: 72,
                child: Icon(
                  Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 44,
                ),
              ),
            ),
          ),
        // Bottom scrim: the identity reads on any frame.
        const IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: [0.45, 0.75, 1],
                colors: [
                  Colors.transparent,
                  Color(0x99000000),
                  Color(0xE6000000),
                ],
              ),
            ),
          ),
        ),
        // Identity: logo, genres, description.
        Positioned(
          left: 16,
          // Clear of the action rail and the floating nav button.
          right: 88,
          bottom: insets.bottom + 24,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: widget.onOpen,
                behavior: HitTestBehavior.opaque,
                child: _ReelTitle(item: item),
              ),
              // Which moment this is.
              if (clipName.isNotEmpty) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Icon(
                      Icons.movie_creation_outlined,
                      size: 14,
                      color: Color(0xCCFFFFFF),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        clipName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Color(0xCCFFFFFF),
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          shadows: [
                            Shadow(color: Colors.black54, blurRadius: 6),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ],
              if (genres.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  genres,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
                  ),
                ),
              ],
              if (description != null && description.isNotEmpty) ...[
                const SizedBox(height: 8),
                _ReelSynopsis(title: item.name, text: description),
              ],
            ],
          ),
        ),
        // Action rail, above the floating nav button.
        Positioned(
          right: 14,
          bottom: insets.bottom + (widget.floatingNav ? 104 : 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ReelAction(
                icon: widget.muted
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
                tooltip: widget.muted ? 'Unmute' : 'Mute',
                onTap: widget.onMute,
              ),
              const SizedBox(height: 16),
              _ReelAction(
                icon: widget.inWatchlist
                    ? Icons.check_rounded
                    : Icons.add_rounded,
                tooltip: widget.inWatchlist
                    ? 'Remove from My Watchlist'
                    : 'Add to My Watchlist',
                selected: widget.inWatchlist,
                onTap: widget.onWatchlist,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A stable poster layer with video painted above it only after first frame.
/// Resolving a URL never replaces or re-decodes the poster widget.
class ReelVideoSurface extends StatelessWidget {
  final ReelPlayback playback;
  final VoidCallback onPlaybackFailed;
  final Widget? poster;
  final Future<TrailerEngine> Function()? engineFactory;

  const ReelVideoSurface({
    super.key,
    required this.playback,
    required this.onPlaybackFailed,
    this.poster,
    this.engineFactory,
  });

  @override
  Widget build(BuildContext context) {
    final item = playback.item;
    final still = item.background ?? item.poster;
    final streams = playback.streams;
    return Stack(
      fit: StackFit.expand,
      children: [
        // This element stays mounted through resolution, playback and errors.
        poster ??
            (still == null
                ? const SizedBox.shrink()
                : CachedNetworkImage(
                    key: ValueKey(still),
                    imageUrl: still,
                    memCacheWidth: 1920,
                    fit: BoxFit.cover,
                    cacheManager: DebrifyImageCache.manager,
                    fadeInDuration: Duration.zero,
                    fadeOutDuration: Duration.zero,
                    useOldImageOnUrlChange: true,
                    errorWidget: (_, _, _) => const SizedBox.shrink(),
                  )),
        IgnorePointer(
          child: HeroTrailerBackdrop(
            imageUrl: null,
            videoUrl: streams?.playUrl,
            audioUrl: streams?.audioUrl,
            enabled:
                (playback.active || playback.prewarm) &&
                streams != null &&
                !playback.failed,
            highResolutionVideo: true,
            suspended: !playback.active || playback.paused,
            freezeFrame: playback.paused,
            initialPosition: playback.initialPosition,
            onPlaybackPosition: playback.onPosition,
            decorative: false,
            fadeDuration: Duration.zero,
            engineFactory: engineFactory,
            onPlaybackFailed: onPlaybackFailed,
            ambientVolume: playback.volume,
            imageBlurSigma: 0,
            videoBlurSigma: 0,
            startDelay: Duration.zero,
            firstFrameTimeout: const Duration(seconds: 15),
            repeat: true,
            skipIntro: false,
          ),
        ),
        if (playback.active && streams == null && !playback.failed)
          const Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: Color(0xCCFFFFFF),
              ),
            ),
          ),
      ],
    );
  }
}

/// The feed has one vertical gesture owner. Full descriptions scroll in a
/// separate sheet, never in a competing scrollable over the reel.
class _ReelSynopsis extends StatelessWidget {
  const _ReelSynopsis({required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: () => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      useSafeArea: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.6,
        child: Column(
          children: [
            ListTile(
              title: Text(title),
              trailing: IconButton(
                tooltip: 'Close description',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                child: Text(text),
              ),
            ),
          ],
        ),
      ),
    ),
    child: Semantics(
      button: true,
      label: 'Show full description',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xE6FFFFFF),
              fontSize: 14,
              height: 1.4,
              shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
            ),
          ),
          const Text(
            'MORE',
            style: TextStyle(
              color: Colors.white,
              fontSize: 12,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    ),
  );
}

/// The title as its logo; the name in type only when no logo is available.
/// A logo's slot is fixed before its request completes, avoiding a flash of
/// text followed by a layout shift when the artwork arrives.
class _ReelTitle extends StatelessWidget {
  final StremioMeta item;

  const _ReelTitle({required this.item});

  @override
  Widget build(BuildContext context) {
    final text = Text(
      item.name,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 26,
        fontWeight: FontWeight.w800,
        height: 1.1,
        letterSpacing: -0.4,
        shadows: [Shadow(color: Colors.black54, blurRadius: 8)],
      ),
    );
    final logo = item.logo;
    if (logo == null || logo.isEmpty) return text;
    final logoSlot = SizedBox(
      width: 230,
      height: 84,
      child: Align(alignment: Alignment.bottomLeft, child: text),
    );
    return SizedBox(
      width: 230,
      height: 84,
      child: CachedNetworkImage(
        imageUrl: logo,
        fit: BoxFit.contain,
        alignment: Alignment.bottomLeft,
        cacheManager: DebrifyImageCache.manager,
        memCacheWidth: 690,
        fadeInDuration: const Duration(milliseconds: 150),
        // Keep the reserved logo space blank while it loads. Rendering the
        // title here makes it vanish and reflow once the image arrives.
        placeholder: (_, _) => const SizedBox.expand(),
        errorWidget: (_, _, _) => logoSlot,
      ),
    );
  }
}

/// A frosted round action button on the right rail.
class _ReelAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool selected;

  const _ReelAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: _GlassCircle(
            size: 52,
            tint: selected ? 0.32 : 0.16,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              transitionBuilder: (child, animation) =>
                  ScaleTransition(scale: animation, child: child),
              child: Icon(
                icon,
                key: ValueKey(icon),
                color: Colors.white,
                size: 26,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _GlassCircle extends StatelessWidget {
  final double size;
  final double tint;
  final Widget child;

  const _GlassCircle({
    required this.size,
    required this.child,
    this.tint = 0.16,
  });

  @override
  Widget build(BuildContext context) {
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white.withValues(alpha: tint),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.28),
              width: 1,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

class _EmptyReels extends StatelessWidget {
  /// This build has no TMDB access, where every clip comes from.
  final bool needsTmdb;
  final bool connectionFailed;
  final VoidCallback? onRetry;

  const _EmptyReels({
    required this.needsTmdb,
    required this.connectionFailed,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.slow_motion_video_rounded,
            size: 48,
            color: Colors.white.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 14),
          Text(
            needsTmdb ? 'Clips need TMDB' : 'No clips right now',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            needsTmdb
                ? 'This build has no TMDB access, where Reels finds its '
                      'clips.'
                : connectionFailed
                ? 'Clips couldn\'t be loaded. Check your connection and retry.'
                : 'No scene clips found in these titles. Search more titles to continue.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 13,
            ),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Retry feed'),
            ),
          ],
        ],
      ),
    );
  }
}
