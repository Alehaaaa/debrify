import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/stremio_addon.dart';
import '../services/debrify_image_cache.dart';
import '../services/main_page_bridge.dart';
import '../services/local_series_completion_service.dart';
import '../services/offline_title_store.dart';
import '../services/profiles/profile_runtime.dart';
import '../services/reels_feed.dart';
import '../services/reel_share_service.dart';
import '../services/storage_service.dart';
import '../services/watchlist_sync_service.dart';
import '../widgets/detail/showcase_parts.dart'
    show DetailGlyphBox, DetailRatingBox;
import '../services/omdb/omdb_ratings_service.dart';
import '../widgets/rotten_tomatoes_score.dart';
import '../services/simkl/simkl_service.dart';
import '../services/trakt/trakt_service.dart';
import '../services/youtube_service.dart';
import '../utils/platform_util.dart';
import '../utils/tv_keys.dart';
import '../widgets/hero_trailer_backdrop.dart';
import '../widgets/trailer_engine.dart';
import '../widgets/watchlist_added_bubble.dart';

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

  /// A player has rendered [streams]' first frame. An open relay connection
  /// keeps streaming past the tunnel's expiry, so a prepared clip is kept.
  bool framed = false;

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
/// The visible reel and one adjacent clip stay prepared where the native
/// player supports it; only the visible reel is audible.
class ReelsScreen extends StatefulWidget {
  final bool isTelevision;

  /// Whether this tab is the shell's currently visible destination.  Reels is
  /// kept alive by the touch tab pager while its neighbour is shown, so this
  /// must be explicit rather than relying on dispose to stop its audio/video.
  final bool isActive;

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
    this.isActive = true,
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
    this.previewing = false,
    this.initialPosition,
    this.onPosition,
    this.onFirstFrameReady,
    this.failed = false,
    this.onPlaybackFailed,
  });

  final StremioMeta item;
  final YoutubeResolvedStreams? streams;
  final bool active;
  final bool failed;
  final VoidCallback? onPlaybackFailed;

  /// The next clip is opening toward its first frame beneath a swipe.
  final bool prewarm;

  /// The paired clip is on screen beside the active one during a swipe: it
  /// plays, muted, so the handoff never waits on a cold or frozen player.
  final bool previewing;
  final double volume;

  /// Tapped to pause: hold the frame, keep the player.
  final bool paused;
  final Duration? initialPosition;
  final ValueChanged<Duration>? onPosition;
  final VoidCallback? onFirstFrameReady;
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
  WatchlistAddedBubbleHandle? _watchlistBubble;

  int _index = 0;
  bool _pageWorkPending = false;
  int? _swipePreviewIndex;
  bool _sharing = false;
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
    _watchlistBubble?.dismiss();
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
        // Publish each confirmed title immediately. Waiting for the whole
        // look-ahead batch lets one slow lookup hold back already-ready reels.
        final titles = await _feed.take(
          1,
          // A reopened Reels tab gets the session-wide unseen queue, never a
          // replay just because the first discovery window ran dry.
          allowRepeat: false,
        );
        if (!_current) return;
        final unseen = await Future.wait([
          for (final title in titles)
            _shouldExclude(
              title.item,
            ).then((excluded) => excluded ? null : title),
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
                    preferMuxed: PlatformUtil.isIosMobile,
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
        reel.framed = false;
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
      reel.framed = false;
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
      final titles = await _feed.take(1, allowRepeat: false);
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
    // An unopened relay tunnel past its expiry can no longer be opened. The
    // paired (prewarmed/previewing) player already holds its connection, so
    // keep that one rather than restarting the clip mid-swipe.
    final preview = _swipePreviewIndex;
    final drag = _dragPage;
    final prepared =
        index ==
        (preview != null && preview != _index
            ? preview
            : (drag != null && drag != _index ? drag : _index + 1));
    if (next.state == _ClipState.ready &&
        next.streams?.needsRefresh == true &&
        !(prepared && next.framed)) {
      YoutubeService.invalidateStreams(next.title.clipKey);
      next.revision++;
      next.streams = null;
      next.framed = false;
      next.state = _ClipState.idle;
    }
    setState(() {
      _index = index;
      _paused = false;
    });
    // Ownership changes at the midpoint: the prepared incoming player starts
    // while the swipe is still moving, rather than after the spring settles.
    _pageWorkPending = true;
    unawaited(_resolve(index));
  }

  void _settlePage() {
    if (!_current) return;
    final pageChanged = _pageWorkPending;
    _pageWorkPending = false;
    setState(() {
      _swipePreviewIndex = null;
    });
    if (!pageChanged) return;
    HapticFeedback.selectionClick();
    // Stream resolution and image decoding can be expensive on low-end
    // devices. Start them after, never during, the page animation.
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
    // A relay tunnel can die without the clip being unavailable: it expired
    // before a loop restart or reconnect, or the instance dropped it. Retry
    // once through direct extraction, resuming at the last position.
    if (reel.streams?.isRelay == true) {
      YoutubeService.markRelayFailed(reel.title.clipKey);
      setState(() {
        reel.revision++;
        reel.streams = null;
        reel.framed = false;
        reel.state = _ClipState.idle;
      });
      unawaited(_resolve(_reels.indexOf(reel)));
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
    if (_reels.isEmpty || _reels[_index].state != _ClipState.ready) return;
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
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          )
          .whenComplete(() {
            _movingByKey = false;
            _settlePage();
          }),
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
      _settlePage();
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _discardFailedAhead(),
      );
      if (_refreshArmed && _index == 0) unawaited(_refreshFirst());
      _refreshArmed = false;
      if (_pull != 0) setState(() => _pull = 0);
      return false;
    }
    // A backward drag primes the previous clip as soon as it appears. Forward
    // swipes already have the next page mounted and preparing at rest.
    final dragPage = _dragPage;
    if (dragPage != null && n.metrics.viewportDimension > 0) {
      final progress =
          n.metrics.pixels / n.metrics.viewportDimension - dragPage;
      final candidate = progress.abs() < .02
          ? null
          : (dragPage + progress.sign.toInt()).clamp(0, _reels.length - 1);
      if (candidate != _swipePreviewIndex) {
        setState(() => _swipePreviewIndex = candidate);
        if (candidate != null) unawaited(_resolve(candidate));
      }
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

  Future<void> _toggleWatchlist(StremioMeta item, {Offset? origin}) async {
    final key = _watchKey(item);
    final next = !(_inWatchlist[key] ?? false);
    setState(() => _inWatchlist[key] = next);
    HapticFeedback.mediumImpact();
    // The confirmation must start from the user's press, not from an async
    // storage completion. A failed write dismisses this optimistic feedback.
    final bubble = next
        ? showWatchlistAddedBubble(context, origin: origin)
        : null;
    if (next) _watchlistBubble = bubble;
    try {
      await WatchlistSyncService.setMyWatchlistItem(
        await _watchlistItem(item),
        next,
      );
      if (!mounted) return;
      if (next) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('Removed from My Watchlist')),
        );
    } catch (_) {
      bubble?.dismiss();
      if (identical(_watchlistBubble, bubble)) _watchlistBubble = null;
      if (!mounted) return;
      setState(() => _inWatchlist[key] = !next);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn\'t update My Watchlist')),
      );
    }
  }

  /// A double tap is intentionally one-way: it is a quick "save this" action,
  /// so it must never remove something the user had already saved.
  void _addToWatchlist(StremioMeta item, Offset origin) {
    if (_inWatchlist[_watchKey(item)] ?? false) return;
    unawaited(_toggleWatchlist(item, origin: origin));
  }

  /// Keep saved and completed titles out of discovery without hiding a title
  /// that is merely in progress. Tracker calls return null when unavailable,
  /// deliberately leaving the candidate eligible rather than treating a
  /// temporary outage as an empty library.
  Future<bool> _shouldExclude(StremioMeta item) async {
    final imdb = item.effectiveImdbId;
    if (imdb == null) return false;
    try {
      final series = item.type == 'series';
      final statuses = await Future.wait<Object?>([
        StorageService.isInMyWatchlist(item),
        series
            ? Future.wait([
                StorageService.getExplicitlyWatchedSeriesIds(),
                LocalSeriesCompletionService.instance.caughtUpIds(),
              ])
            : StorageService.isMovieFinished(imdb),
        TraktService.instance.fetchTitleStatus(imdb, item.type),
        SimklService.instance.fetchTitleStatus(imdb, contentType: item.type),
      ]);
      final localWatchlist = statuses[0] as bool;
      final localFinished = series
          ? (statuses[1] as List<Object?>).cast<Set<String>>().any(
              (ids) => ids.contains(imdb.toLowerCase()),
            )
          : statuses[1] as bool;
      final trakt = statuses[2] as TraktTitleStatus?;
      final simkl = statuses[3] as SimklTitleStatus?;
      return localWatchlist ||
          localFinished ||
          trakt?.inWatchlist == true ||
          trakt?.titleWatched == true ||
          simkl?.currentStatus == 'plantowatch' ||
          simkl?.currentStatus == 'completed';
    } catch (_) {
      return false;
    }
  }

  Future<void> _share(_Reel reel, Rect origin) async {
    if (_sharing) return;
    HapticFeedback.selectionClick();
    setState(() => _sharing = true);
    try {
      await const ReelShareService().share(context, reel.title, origin: origin);
    } finally {
      if (mounted) setState(() => _sharing = false);
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
      // The next Reel is opened and parked on its first frame while this one
      // plays. During a drag the other visible page — the incoming one, or,
      // past the midpoint, the outgoing one — is the paired player instead,
      // and it plays muted so both halves of the screen stay live. Only the
      // page that owns the majority of the screen ([_index]) is audible.
      final preview = _swipePreviewIndex;
      final dragPage = _dragPage;
      final companion = preview != null && preview != _index
          ? preview
          : (dragPage != null && dragPage != _index ? dragPage : null);
      final prewarmIndex = companion ?? _index + 1;
      final canPreview = !kIsWeb && !PlatformUtil.isTvOS;
      body = NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: PageView.builder(
          controller: _pages,
          // Lay out the adjacent page before a gesture. KeepAlive alone cannot
          // prepare an item that the sliver has never built.
          allowImplicitScrolling: true,
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
              playbackActive: widget.isActive && i == _index,
              // Preparation begins while the current Reel is playing and
              // continues for the page visible beneath a swipe.
              prewarm: widget.isActive && !_sharing && i == prewarmIndex,
              previewing:
                  canPreview && widget.isActive && !_sharing && i == companion,
              onPlaybackFailed: () => _playbackFailed(reel, revision),
              onRetry: () => _retry(reel),
              floatingNav: widget.floatingNav,
              paused: !widget.isActive || _sharing || (i == _index && _paused),
              showPauseOverlay: i == _index && _paused,
              onTogglePause: _togglePause,
              muted: _muted,
              inWatchlist: _inWatchlist[_watchKey(reel.item)] ?? false,
              onMute: _toggleMute,
              onWatchlist: (origin) =>
                  _toggleWatchlist(reel.item, origin: origin),
              onAddToWatchlist: (origin) => _addToWatchlist(reel.item, origin),
              onOpen: () => _open(reel.item),
              onShare: (origin) => _share(reel, origin),
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

  // A firm, near-critical snap makes the end of a Reel swipe feel decisive
  // without the prolonged soft ease of the default page spring.
  static const _snapSpring = SpringDescription(
    mass: 0.55,
    stiffness: 520,
    damping: 30,
  );

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
      _snapSpring,
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
  final bool playbackActive;
  final bool prewarm;
  final bool previewing;
  final bool floatingNav;
  final VoidCallback onPlaybackFailed;
  final VoidCallback onRetry;
  final bool paused;
  final bool showPauseOverlay;
  final VoidCallback onTogglePause;
  final bool muted;
  final bool inWatchlist;
  final VoidCallback onMute;
  final ValueChanged<Offset?> onWatchlist;
  final ValueChanged<Offset> onAddToWatchlist;
  final VoidCallback onOpen;
  final ValueChanged<Rect> onShare;
  final ValueChanged<Duration> onPosition;
  final Widget Function(ReelPlayback playback)? playerBuilder;

  const _ReelPage({
    super.key,
    required this.reel,
    required this.active,
    required this.playbackActive,
    required this.prewarm,
    this.previewing = false,
    required this.floatingNav,
    required this.onPlaybackFailed,
    required this.onRetry,
    required this.paused,
    required this.showPauseOverlay,
    required this.onTogglePause,
    required this.muted,
    required this.inWatchlist,
    required this.onMute,
    required this.onWatchlist,
    required this.onAddToWatchlist,
    required this.onOpen,
    required this.onShare,
    required this.onPosition,
    required this.playerBuilder,
  });

  @override
  State<_ReelPage> createState() => _ReelPageState();
}

class _ReelPageState extends State<_ReelPage>
    with AutomaticKeepAliveClientMixin {
  static const _doubleTapWindow = Duration(milliseconds: 180);
  Timer? _pauseTapTimer;
  Offset? _firstTapPosition;
  Offset? _tapDownPosition;
  bool _tapDragged = false;
  Offset? _watchlistOrigin;
  final GlobalKey _watchlistActionKey = GlobalKey();
  final GlobalKey _shareActionKey = GlobalKey();
  @override
  bool get wantKeepAlive => widget.prewarm;

  @override
  void didUpdateWidget(covariant _ReelPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.prewarm != oldWidget.prewarm) updateKeepAlive();
    if (!widget.active) {
      _pauseTapTimer?.cancel();
      _pauseTapTimer = null;
      _firstTapPosition = null;
    }
  }

  @override
  void dispose() {
    _pauseTapTimer?.cancel();
    super.dispose();
  }

  void _onVideoPointerDown(PointerDownEvent event) {
    _tapDragged = false;
    _tapDownPosition = event.position;
  }

  void _onVideoPointerMove(PointerMoveEvent event) {
    final down = _tapDownPosition;
    if (down != null && (event.position - down).distanceSquared > 1600) {
      _tapDragged = true;
    }
  }

  void _onVideoPointerUp(PointerUpEvent event) {
    if (_tapDragged) {
      _pauseTapTimer?.cancel();
      _pauseTapTimer = null;
      _firstTapPosition = null;
      _tapDownPosition = null;
      return;
    }
    _tapDownPosition = null;
    final first = _firstTapPosition;
    if (_pauseTapTimer != null &&
        first != null &&
        (event.position - first).distanceSquared <= 1600) {
      _pauseTapTimer!.cancel();
      _pauseTapTimer = null;
      _firstTapPosition = null;
      widget.onAddToWatchlist(event.position);
      return;
    }
    _pauseTapTimer?.cancel();
    _firstTapPosition = event.position;
    _pauseTapTimer = Timer(_doubleTapWindow, () {
      _pauseTapTimer = null;
      _firstTapPosition = null;
      if (mounted && widget.active) widget.onTogglePause();
    });
  }

  Offset _watchlistButtonCenter() {
    final box =
        _watchlistActionKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return Offset.zero;
    return box.localToGlobal(box.size.center(Offset.zero));
  }

  void _toggleWatchlistFromAction() {
    final origin = _watchlistOrigin ?? _watchlistButtonCenter();
    _watchlistOrigin = null;
    widget.onWatchlist(origin);
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
      active: widget.playbackActive,
      volume: widget.muted || !widget.playbackActive ? 0 : 100,
      paused: widget.paused,
      prewarm: widget.prewarm && reel.state != _ClipState.failed,
      previewing:
          widget.previewing &&
          widget.prewarm &&
          reel.state != _ClipState.failed,
      initialPosition: reel.position > Duration.zero ? reel.position : null,
      onPosition: widget.onPosition,
      onFirstFrameReady: () => reel.framed = true,
      failed: reel.state == _ClipState.failed,
      onPlaybackFailed: widget.onPlaybackFailed,
    );
    final genres = (item.genres ?? const <String>[]).take(4).join(' • ');
    final rating = item.imdbRating;
    final omdbId = item.effectiveImdbId;
    final hasOmdb =
        OmdbRatingsService.instance.enabled &&
        OmdbRatingsService.isImdbId(omdbId);
    final description = item.description?.trim();
    final clipName = reel.title.clipName;
    return Stack(
      fit: StackFit.expand,
      children: [
        // The video itself: a tap pauses or resumes it. The title, text and
        // buttons above keep their own taps.
        Listener(
          onPointerDown: _onVideoPointerDown,
          onPointerMove: _onVideoPointerMove,
          onPointerUp: _onVideoPointerUp,
          onPointerCancel: (_) {
            _tapDragged = true;
            _pauseTapTimer?.cancel();
            _pauseTapTimer = null;
            _firstTapPosition = null;
          },
          behavior: HitTestBehavior.opaque,
          child:
              widget.playerBuilder?.call(playback) ??
              ReelVideoSurface(
                playback: playback,
                onPlaybackFailed: widget.onPlaybackFailed,
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
        if (widget.paused && widget.showPauseOverlay)
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
              if (genres.isNotEmpty || rating != null || hasOmdb) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (genres.isNotEmpty)
                      Flexible(
                        fit: FlexFit.loose,
                        child: Text(
                          genres,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            shadows: [
                              Shadow(color: Colors.black54, blurRadius: 6),
                            ],
                          ),
                        ),
                      ),
                    if (genres.isNotEmpty && rating != null)
                      const SizedBox(width: 8),
                    // The detail badge's native type is 7.5px. Scale every
                    // part of it together to a quieter 11px readout beside
                    // this 13px genre line without changing the detail UI.
                    if (rating != null)
                      DetailRatingBox(value: rating, scale: 11 / 7.5),
                    // Rotten Tomatoes + Metacritic (OMDb) as twin boxes, and
                    // OMDb's IMDb when the reel has none of its own.
                    if (hasOmdb)
                      OmdbRatingsBuilder(
                        imdbId: omdbId,
                        builder: (context, r) {
                          if (r == null) return const SizedBox.shrink();
                          final boxes = <Widget>[
                            if (rating == null && r.imdb != null)
                              DetailRatingBox(value: r.imdb!, scale: 11 / 7.5),
                            if (r.score != null)
                              DetailGlyphBox(
                                glyph: (size, color) =>
                                    TomatoGlyph(size: size, color: color),
                                label: '${r.score}%',
                                scale: 11 / 7.5,
                              ),
                            if (r.metacritic != null)
                              DetailGlyphBox(
                                glyph: (size, color) =>
                                    MetacriticGlyph(size: size, color: color),
                                label: '${r.metacritic}',
                                scale: 11 / 7.5,
                              ),
                          ];
                          final leading = genres.isNotEmpty || rating != null;
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (var i = 0; i < boxes.length; i++) ...[
                                if (i > 0 || leading) const SizedBox(width: 6),
                                boxes[i],
                              ],
                            ],
                          );
                        },
                      ),
                  ],
                ),
              ],
              if (description != null && description.isNotEmpty) ...[
                const SizedBox(height: 8),
                _ReelSynopsis(text: description),
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
                label: widget.muted ? 'Unmute' : 'Sound',
                onTap: widget.onMute,
              ),
              const SizedBox(height: 16),
              _ReelAction(
                key: _watchlistActionKey,
                icon: widget.inWatchlist
                    ? Icons.check_rounded
                    : Icons.add_rounded,
                tooltip: widget.inWatchlist
                    ? 'Remove from My Watchlist'
                    : 'Add to My Watchlist',
                selected: widget.inWatchlist,
                label: widget.inWatchlist ? 'Saved' : 'Save',
                onTap: _toggleWatchlistFromAction,
                onTapDown: (origin) {
                  _watchlistOrigin = origin;
                },
              ),
              const SizedBox(height: 16),
              _ReelAction(
                key: _shareActionKey,
                icon: Icons.ios_share_rounded,
                tooltip: 'Share clip',
                label: 'Share',
                onTap: () {
                  final box =
                      _shareActionKey.currentContext?.findRenderObject()
                          as RenderBox?;
                  if (box != null) {
                    widget.onShare(box.localToGlobal(Offset.zero) & box.size);
                  }
                },
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
            // iOS's AVPlayer platform view consumes one muxed URL.  Falling
            // back to media_kit here made the entire Flutter scene recompose
            // for each frame, which is especially noticeable while paging.
            muxedVideoUrl: streams?.muxedPlaybackFallback,
            enabled:
                (playback.active || playback.prewarm) &&
                streams != null &&
                !playback.failed,
            highResolutionVideo: true,
            suspended:
                !(playback.active || playback.previewing) || playback.paused,
            // iOS may have the next frame ready before the swipe settles.
            // Keep that paused frame visible rather than falling back to its
            // poster, then let it start directly once it becomes active.
            freezeFrame:
                playback.paused || (playback.prewarm && !playback.previewing),
            // Current + next are a decoder pair: AVPlayer, Exo and media_kit
            // (off tvOS, via a shared output lease) all prime the next clip
            // in parallel while the visible one plays. tvOS keeps the single
            // serialized output and starts once the outgoing reel yields it.
            prewarm: playback.prewarm,
            pairedOutput: true,
            initialPosition: playback.initialPosition,
            onPlaybackPosition: playback.onPosition,
            onFirstFrameReady: playback.onFirstFrameReady,
            decorative: false,
            fadeDuration: Duration.zero,
            engineFactory: engineFactory,
            onPlaybackFailed: onPlaybackFailed,
            ambientVolume: playback.active && !playback.paused
                ? playback.volume
                : 0,
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

/// Expands inline so the Reel remains one continuous surface; opening a sheet
/// here would interrupt the feed's light, swipe-first interaction.
class _ReelSynopsis extends StatefulWidget {
  const _ReelSynopsis({required this.text});

  final String text;

  @override
  State<_ReelSynopsis> createState() => _ReelSynopsisState();
}

class _ReelSynopsisState extends State<_ReelSynopsis> {
  bool _expanded = false;

  static const _style = TextStyle(
    color: Color(0xE6FFFFFF),
    fontSize: 14,
    height: 1.4,
    shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final hasMore = TextPainter(
        text: TextSpan(text: widget.text, style: _style),
        maxLines: 3,
        textDirection: Directionality.of(context),
      )..layout(maxWidth: constraints.maxWidth);
      final canExpand = hasMore.didExceedMaxLines;
      hasMore.dispose();
      final expanded = _expanded && canExpand;

      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.text,
            maxLines: expanded ? null : 3,
            overflow: expanded ? TextOverflow.visible : TextOverflow.ellipsis,
            style: _style,
          ),
          if (canExpand)
            Text(
              expanded ? 'LESS' : 'MORE',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
        ],
      );
      if (!canExpand) return content;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _expanded = !_expanded),
        child: Semantics(
          button: true,
          label: expanded ? 'Collapse description' : 'Show full description',
          child: content,
        ),
      );
    },
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
  final String label;
  final VoidCallback onTap;
  final ValueChanged<Offset>? onTapDown;
  final bool selected;

  const _ReelAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.onTapDown,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        label: tooltip,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTapDown: (details) => onTapDown?.call(details.globalPosition),
            onTap: onTap,
            borderRadius: BorderRadius.circular(26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _GlassCircle(
                  size: 52,
                  tint: selected ? 0.32 : 0.16,
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 160),
                    child: Icon(
                      icon,
                      key: ValueKey(icon),
                      color: Colors.white,
                      size: 26,
                    ),
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    shadows: [Shadow(color: Colors.black87, blurRadius: 6)],
                  ),
                ),
              ],
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
    // A stable translucent surface avoids three live backdrop-blur passes
    // over every video frame while the feed is scrolling.
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Color.lerp(const Color(0xB3000000), Colors.white, tint),
        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
      ),
      child: child,
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
