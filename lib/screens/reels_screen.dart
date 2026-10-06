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
import '../services/youtube_service.dart';
import '../utils/tv_keys.dart';
import '../widgets/detail/showcase_parts.dart' show ExpandableSynopsis;
import '../widgets/hero_trailer_backdrop.dart';

/// A reel in the feed: the title, its clip, and that clip's stream once
/// it has been resolved (only ever for the reel on screen and the next one).
class _Reel {
  _Reel(this.title);

  final ReelTitle title;
  YoutubeResolvedStreams? streams;
  bool resolving = false;
  bool failed = false;

  StremioMeta get item => title.item;
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
/// is resolved only for the reel that settles on screen and the one after
/// it; reels flung past are never resolved at all. Only the reel on screen
/// holds a decoder.
class ReelsScreen extends StatefulWidget {
  final bool isTelevision;

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
  });

  final StremioMeta item;
  final YoutubeResolvedStreams? streams;
  final bool active;
  final double volume;
}

class _ReelsScreenState extends State<ReelsScreen> {
  /// Sound on or off, for the whole feed — kept for the app session so the
  /// choice survives leaving the tab.
  static bool _muted = false;

  /// Confirmed titles kept queued past the one on screen, so a fling never
  /// runs into the end of the feed. Each costs one request.
  static const int _ahead = 3;

  /// How far the first reel must be pulled down to refresh it.
  static const double _refreshPull = 90;

  /// How long a page must stay put before its clip is resolved: a fling
  /// passes through pages faster than this and resolves none of them.
  static const Duration _settle = Duration(milliseconds: 150);

  late final ReelsFeed _feed = widget.feed ?? ReelsFeed();
  final PageController _pages = PageController();
  final FocusNode _focus = FocusNode(debugLabel: 'reels');
  final Object? _scope = ProfileRuntime.scope.value;
  final List<_Reel> _reels = [];
  final Map<String, bool> _inWatchlist = {};

  int _index = 0;
  bool _filling = false;
  bool _exhausted = false;
  bool _refreshing = false;
  double _pull = 0;
  Timer? _settleTimer;

  bool get _current => mounted && ProfileRuntime.scope.value == _scope;

  @override
  void initState() {
    super.initState();
    if (!_feed.available) {
      _exhausted = true;
      return;
    }
    unawaited(_fill());
  }

  @override
  void dispose() {
    _settleTimer?.cancel();
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
      final need = _index + 1 + _ahead - _reels.length;
      if (need <= 0) return;
      final titles = await _feed.take(need);
      if (!_current) return;
      final first = _reels.isEmpty;
      setState(() {
        _reels.addAll(titles.map(_Reel.new));
        if (titles.isEmpty) _exhausted = true;
      });
      for (final title in titles) {
        unawaited(_loadWatchlist(title.item));
      }
      if (first) _prepare();
    } finally {
      _filling = false;
    }
  }

  /// Resolve the clip on screen, then the next one.
  void _prepare() {
    unawaited(() async {
      await _resolve(_index);
      await _resolve(_index + 1);
    }());
  }

  Future<void> _resolve(int index) async {
    if (index < 0 || index >= _reels.length) return;
    final reel = _reels[index];
    if (reel.streams != null || reel.failed || reel.resolving) return;
    reel.resolving = true;
    YoutubeResolvedStreams? streams;
    try {
      streams =
          await (widget.resolver?.call(reel.title.clipKey) ??
              YoutubeService.resolveStreams(
                reel.title.clipKey,
                // Full-bleed on a phone: a portrait crop of a 16:9 frame wants
                // more lines than a card preview.
                maxHeightOverride: 720,
                preferVp9: false,
              ));
    } catch (_) {
      streams = null;
    }
    if (!_current) return;
    setState(() {
      reel.resolving = false;
      if (streams != null && streams.hasPlayable) {
        reel.streams = streams;
      } else {
        reel.failed = true;
      }
    });
    // The clip on screen can't play: don't leave the viewer on a still.
    // (After the frame: the very first reel can fail before the feed's
    // page view has been laid out.)
    if (reel.failed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _reels.indexOf(reel) == _index) _go(_index + 1);
      });
    }
  }

  /// Pull-down on the first reel: swap it for a fresh title.
  Future<void> _refreshFirst() async {
    if (_refreshing || !_feed.available) return;
    setState(() => _refreshing = true);
    HapticFeedback.mediumImpact();
    try {
      final titles = await _feed.take(1);
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
    setState(() => _index = index);
    HapticFeedback.selectionClick();
    unawaited(_fill());
    _settleTimer?.cancel();
    _settleTimer = Timer(_settle, () {
      if (mounted && _index == index) _prepare();
    });
  }

  /// DPAD / keyboard: up and down move through the feed, OK opens the title.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
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
    if (event is KeyDownEvent && isActivateOrSpaceKey(key)) {
      if (_index < _reels.length) _open(_reels[_index].item);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _go(int index) {
    if (index < 0 || index >= _reels.length || !_pages.hasClients) return;
    _pages.animateToPage(
      index,
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
    );
  }

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0 || _index != 0) return false;
    // Pulled past the top of the first reel (the bounce shows it as negative
    // offset): follow the finger, and refresh once it lets go far enough.
    if (n is ScrollUpdateNotification) {
      final pull = (-n.metrics.pixels).clamp(0.0, double.infinity);
      if (pull != _pull) setState(() => _pull = pull);
      if (n.dragDetails == null && _pull >= _refreshPull) {
        unawaited(_refreshFirst());
      }
    } else if (n is OverscrollNotification && n.overscroll < 0) {
      // Clamping physics report the pull as overscroll instead.
      setState(() => _pull = (_pull - n.overscroll).clamp(0.0, 200.0));
    } else if (n is ScrollEndNotification) {
      if (_pull >= _refreshPull) unawaited(_refreshFirst());
      if (_pull != 0) setState(() => _pull = 0);
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

  void _toggleMute() {
    HapticFeedback.selectionClick();
    setState(() => _muted = !_muted);
  }

  /// The title's full page, opened by the Home board (which owns the detail
  /// page and its Play / Sources machinery); closing it comes back here.
  void _open(StremioMeta item) {
    final imdb = item.effectiveImdbId;
    if (imdb == null) return;
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
            ? _EmptyReels(needsTmdb: !_feed.available)
            : const CircularProgressIndicator(color: Colors.white),
      );
    } else {
      body = NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: PageView.builder(
          controller: _pages,
          scrollDirection: Axis.vertical,
          // The bounce is what lets the first reel be pulled down.
          physics: const PageScrollPhysics(parent: BouncingScrollPhysics()),
          onPageChanged: _onPage,
          itemCount: _reels.length,
          itemBuilder: (context, i) {
            final reel = _reels[i];
            return _ReelPage(
              key: ValueKey(_watchKey(reel.item)),
              reel: reel,
              active: i == _index,
              muted: _muted,
              inWatchlist: _inWatchlist[_watchKey(reel.item)] ?? false,
              onMute: _toggleMute,
              onWatchlist: () => _toggleWatchlist(reel.item),
              onOpen: () => _open(reel.item),
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

/// One reel: the clip, the scrim, the identity bottom-left and the action
/// rail on the right.
class _ReelPage extends StatelessWidget {
  final _Reel reel;
  final bool active;
  final bool muted;
  final bool inWatchlist;
  final VoidCallback onMute;
  final VoidCallback onWatchlist;
  final VoidCallback onOpen;
  final Widget Function(ReelPlayback playback)? playerBuilder;

  const _ReelPage({
    super.key,
    required this.reel,
    required this.active,
    required this.muted,
    required this.inWatchlist,
    required this.onMute,
    required this.onWatchlist,
    required this.onOpen,
    required this.playerBuilder,
  });

  @override
  Widget build(BuildContext context) {
    final item = reel.item;
    final insets = MediaQuery.paddingOf(context);
    final playback = ReelPlayback(
      item: item,
      streams: reel.streams,
      active: active,
      volume: muted ? 0 : 100,
    );
    final genres = (item.genres ?? const <String>[]).take(4).join(' • ');
    final description = item.description?.trim();
    final clipName = reel.title.clipName;
    return Stack(
      fit: StackFit.expand,
      children: [
        playerBuilder?.call(playback) ?? _ReelPlayer(playback: playback),
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
                onTap: onOpen,
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
                ConstrainedBox(
                  // An expanded description scrolls rather than covering the
                  // clip end to end.
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(context).height * 0.4,
                  ),
                  child: SingleChildScrollView(
                    child: ExpandableSynopsis(
                      text: description,
                      maxLines: 3,
                      style: const TextStyle(
                        color: Color(0xE6FFFFFF),
                        fontSize: 14,
                        height: 1.4,
                        shadows: [Shadow(color: Colors.black54, blurRadius: 6)],
                      ),
                      actionStyle: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
        // Action rail, above the floating nav button.
        Positioned(
          right: 14,
          bottom: insets.bottom + 104,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ReelAction(
                icon: muted
                    ? Icons.volume_off_rounded
                    : Icons.volume_up_rounded,
                tooltip: muted ? 'Unmute' : 'Mute',
                onTap: onMute,
              ),
              const SizedBox(height: 16),
              _ReelAction(
                icon: inWatchlist ? Icons.check_rounded : Icons.add_rounded,
                tooltip: inWatchlist
                    ? 'Remove from My Watchlist'
                    : 'Add to My Watchlist',
                selected: inWatchlist,
                onTap: onWatchlist,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The clip, looping, full-bleed. Only the reel on screen plays; the others
/// show their still (as does this one until its clip is resolved), so one
/// decoder serves the whole feed.
class _ReelPlayer extends StatelessWidget {
  final ReelPlayback playback;

  const _ReelPlayer({required this.playback});

  @override
  Widget build(BuildContext context) {
    final item = playback.item;
    final still = item.background ?? item.poster;
    final streams = playback.streams;
    if (!playback.active || streams == null) {
      final image = still == null
          ? const SizedBox.shrink()
          : CachedNetworkImage(
              imageUrl: still,
              fit: BoxFit.cover,
              cacheManager: DebrifyImageCache.manager,
              fadeInDuration: Duration.zero,
              errorWidget: (_, _, _) => const SizedBox.shrink(),
            );
      if (!playback.active) return image;
      // On screen, clip still on its way: the still, and a quiet spinner.
      return Stack(
        fit: StackFit.expand,
        children: [
          image,
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
    return IgnorePointer(
      child: HeroTrailerBackdrop(
        imageUrl: still,
        videoUrl: streams.playUrl,
        audioUrl: streams.audioUrl,
        muxedVideoUrl: streams.muxedPlaybackFallback,
        enabled: true,
        ambientVolume: playback.volume,
        imageBlurSigma: 0,
        videoBlurSigma: 0,
        sharpStill: true,
        startDelay: Duration.zero,
        firstFrameTimeout: const Duration(seconds: 15),
        // A reel loops until you swipe on, like any short-video feed — and
        // a scene clip starts on the scene, so nothing is skipped.
        repeat: true,
        skipIntro: false,
      ),
    );
  }
}

/// The title as its logo; the name in type when there is no logo (or it
/// fails to load).
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
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 230, maxHeight: 84),
      child: CachedNetworkImage(
        imageUrl: logo,
        fit: BoxFit.contain,
        alignment: Alignment.bottomLeft,
        cacheManager: DebrifyImageCache.manager,
        memCacheWidth: 690,
        fadeInDuration: const Duration(milliseconds: 150),
        placeholder: (_, _) => text,
        errorWidget: (_, _, _) => text,
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

  const _EmptyReels({required this.needsTmdb});

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
                : 'Clips couldn\'t be loaded. Check your connection and try '
                      'again later.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}
