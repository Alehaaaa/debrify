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
import '../services/stremio_service.dart';
import '../services/title_trailer_resolver.dart';
import '../services/youtube_service.dart';
import '../utils/tv_keys.dart';
import '../widgets/detail/showcase_parts.dart' show ExpandableSynopsis;
import '../widgets/hero_trailer_backdrop.dart';

/// A clip ready to show: the title (with its full details) and its trailer.
class _Reel {
  _Reel(this.item, this.streams);

  final StremioMeta item;
  final YoutubeResolvedStreams streams;
}

/// Reels: a vertical feed of trailer clips, one title per screen.
///
/// Swipe up for the next title, down for the previous; pulling down on the
/// first one swaps it for a fresh title. Each reel plays its clip full-bleed
/// with the title's logo, genres and an expandable description at the
/// bottom-left, and on the right a mute toggle and an Add to My Watchlist
/// button. Tapping the title opens its full page (and Back returns here).
///
/// Only the reel on screen holds a decoder; the next couple of titles are
/// resolved ahead, and a title whose clip can't be found never reaches the
/// screen.
class ReelsScreen extends StatefulWidget {
  final bool isTelevision;

  /// Test seams. Production uses the Cinemeta feed, the shared trailer
  /// resolver and the catalog's full-details fetch.
  @visibleForTesting
  final ReelsFeed? feed;
  @visibleForTesting
  final Future<YoutubeResolvedStreams?> Function(StremioMeta item)? resolver;
  @visibleForTesting
  final Future<StremioMeta?> Function(StremioMeta item)? details;

  /// Test seam: what plays behind a reel. Production uses
  /// [HeroTrailerBackdrop].
  @visibleForTesting
  final Widget Function(ReelPlayback playback)? playerBuilder;

  const ReelsScreen({
    super.key,
    this.isTelevision = false,
    this.feed,
    this.resolver,
    this.details,
    this.playerBuilder,
  });

  @override
  State<ReelsScreen> createState() => _ReelsScreenState();
}

/// What one reel's player is asked to do.
class ReelPlayback {
  const ReelPlayback({
    required this.item,
    required this.streams,
    required this.active,
    required this.volume,
  });

  final StremioMeta item;
  final YoutubeResolvedStreams streams;
  final bool active;
  final double volume;
}

class _ReelsScreenState extends State<ReelsScreen> {
  /// Sound on or off, for the whole feed — kept for the app session so the
  /// choice survives leaving the tab.
  static bool _muted = false;

  /// How many resolved reels to keep queued past the one on screen.
  static const int _ahead = 2;

  /// How far the first reel must be pulled down to refresh it.
  static const double _refreshPull = 90;

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

  bool get _current => mounted && ProfileRuntime.scope.value == _scope;

  @override
  void initState() {
    super.initState();
    unawaited(_fill());
  }

  @override
  void dispose() {
    _pages.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ── feed ───────────────────────────────────────────────────────────────

  /// The next title with a playable clip, with its full details — or null
  /// when the catalogs have run dry.
  Future<_Reel?> _nextReel() async {
    while (_current) {
      final candidate = await _feed.next();
      if (candidate == null) return null;
      final item = await _withDetails(candidate);
      if (!_current) return null;
      YoutubeResolvedStreams? streams;
      try {
        streams =
            await (widget.resolver?.call(item) ??
                resolveTitleTrailer(
                  item,
                  isCurrent: () => _current,
                  // Full-bleed on a phone: a portrait crop of a 16:9 frame wants
                  // more lines than a card preview.
                  maxHeight: 720,
                ));
      } catch (_) {
        streams = null;
      }
      // No clip, no reel: on to the next title before anyone sees this one.
      if (streams != null) return _Reel(item, streams);
    }
    return null;
  }

  /// Catalog rows are previews; the reel wants the logo, genres and the
  /// whole description, which the full details carry.
  Future<StremioMeta> _withDetails(StremioMeta item) async {
    final complete =
        (item.logo ?? '').isNotEmpty &&
        (item.description ?? '').isNotEmpty &&
        (item.genres ?? const []).isNotEmpty;
    if (complete) return item;
    try {
      final imdb = item.effectiveImdbId;
      final details =
          await (widget.details?.call(item) ??
              (imdb == null
                  ? Future<StremioMeta?>.value()
                  : StremioService.instance.fetchMetaDetails(
                      imdbId: imdb,
                      type: item.type,
                    )));
      if (details == null) return item;
      final addon = item.sourceAddon;
      return addon == null ? details : details.withSourceAddon(addon);
    } catch (_) {
      return item;
    }
  }

  /// Keep [_ahead] reels queued past the one on screen.
  Future<void> _fill() async {
    if (_filling || _exhausted) return;
    _filling = true;
    try {
      while (_current && _reels.length - _index - 1 < _ahead) {
        final reel = await _nextReel();
        if (!_current) return;
        if (reel == null) {
          setState(() => _exhausted = true);
          return;
        }
        setState(() => _reels.add(reel));
        unawaited(_loadWatchlist(reel.item));
      }
    } finally {
      _filling = false;
    }
  }

  /// Pull-down on the first reel: swap it for a fresh title.
  Future<void> _refreshFirst() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    HapticFeedback.mediumImpact();
    try {
      final reel = await _nextReel();
      if (!_current || reel == null) return;
      setState(() {
        if (_reels.isEmpty) {
          _reels.add(reel);
        } else {
          _reels[0] = reel;
        }
      });
      unawaited(_loadWatchlist(reel.item));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  void _onPage(int index) {
    setState(() => _index = index);
    HapticFeedback.selectionClick();
    unawaited(_fill());
  }

  /// DPAD / keyboard: up and down move through the feed, OK opens the title.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      if (_index < _reels.length - 1) _go(_index + 1);
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

  void _go(int index) => _pages.animateToPage(
    index,
    duration: const Duration(milliseconds: 320),
    curve: Curves.easeOutCubic,
  );

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
            ? const _EmptyReels()
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
/// show their still, so one decoder serves the whole feed.
class _ReelPlayer extends StatelessWidget {
  final ReelPlayback playback;

  const _ReelPlayer({required this.playback});

  @override
  Widget build(BuildContext context) {
    final item = playback.item;
    final still = item.background ?? item.poster;
    if (!playback.active) {
      return still == null
          ? const SizedBox.shrink()
          : CachedNetworkImage(
              imageUrl: still,
              fit: BoxFit.cover,
              cacheManager: DebrifyImageCache.manager,
              fadeInDuration: Duration.zero,
              errorWidget: (_, _, _) => const SizedBox.shrink(),
            );
    }
    final streams = playback.streams;
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
        // A reel loops until you swipe on, like any short-video feed.
        repeat: true,
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
  const _EmptyReels();

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
          const Text(
            'No clips right now',
            style: TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Trailers couldn\'t be loaded. Check your connection and try '
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
