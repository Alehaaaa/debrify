import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/main_page_bridge.dart';
import '../services/reel_share_service.dart';
import '../services/reels_feed.dart';
import '../services/storage/watchlist_storage.dart';
import '../services/youtube_service.dart';
import '../theme/app_theme_scope.dart';
import '../theme/glass_chrome.dart';
import '../widgets/hero_trailer_backdrop.dart';
import '../widgets/rotten_tomatoes_score.dart';

/// Full-screen vertical feed of official scene clips.
///
/// Discovery remains in [ReelsFeed]; playback uses the refactored shared
/// YouTube resolver and trailer surface instead of restoring the fork's former
/// duplicate storage/player stack.
class ReelsScreen extends StatefulWidget {
  const ReelsScreen({super.key});

  @override
  State<ReelsScreen> createState() => _ReelsScreenState();
}

class _ReelsScreenState extends State<ReelsScreen> {
  static const int _batchSize = 6;

  final PageController _controller = PageController();
  final ReelsFeed _feed = ReelsFeed();
  final List<ReelTitle> _items = <ReelTitle>[];
  final Map<String, YoutubeResolvedStreams?> _streams =
      <String, YoutubeResolvedStreams?>{};
  final Set<String> _resolving = <String>{};
  final Map<String, bool> _saved = <String, bool>{};

  bool _loading = false;
  String? _error;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMore());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadMore() async {
    if (_loading || !_feed.available) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final next = await _feed.take(_batchSize, allowRepeat: _items.isNotEmpty);
      if (!mounted) return;
      setState(() => _items.addAll(next));
      if (_items.isNotEmpty) {
        unawaited(_resolveAt(_currentIndex));
        unawaited(_resolveAt(_currentIndex + 1));
        unawaited(_loadSaved(_currentIndex));
      }
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resolveAt(int index) async {
    if (index < 0 || index >= _items.length) return;
    final id = _items[index].clipKey;
    if (_streams.containsKey(id) || !_resolving.add(id)) return;
    try {
      final streams = await YoutubeService.resolveStreams(
        id,
        maxHeightOverride: 1080,
      );
      if (!mounted) return;
      setState(() => _streams[id] = streams);
    } catch (_) {
      if (mounted) setState(() => _streams[id] = null);
    } finally {
      _resolving.remove(id);
    }
  }

  void _onPageChanged(int index) {
    setState(() => _currentIndex = index);
    unawaited(_resolveAt(index));
    unawaited(_resolveAt(index + 1));
    unawaited(_loadSaved(index));
    if (index >= _items.length - 3) unawaited(_loadMore());
  }

  String _savedKey(ReelTitle reel) => '${reel.item.type}:${reel.item.id}';

  Future<void> _loadSaved(int index) async {
    if (index < 0 || index >= _items.length) return;
    final reel = _items[index];
    final key = _savedKey(reel);
    if (_saved.containsKey(key)) return;
    final saved = await WatchlistStorage.isInMyWatchlist(reel.item);
    if (mounted) setState(() => _saved[key] = saved);
  }

  Future<void> _toggleSaved(ReelTitle reel) async {
    final key = _savedKey(reel);
    final next = !(_saved[key] ?? false);
    setState(() => _saved[key] = next);
    HapticFeedback.mediumImpact();
    try {
      await WatchlistStorage.setMyWatchlistItem(reel.item, next);
    } catch (_) {
      if (mounted) setState(() => _saved[key] = !next);
    }
  }

  Future<void> _share(ReelTitle reel) async {
    // Open the system share sheet (Android/iOS/macOS); unsupported platforms
    // fall back to the service's glass copy/open sheet. A null origin lets the
    // native handler centre the iPad/macOS popover.
    await const ReelShareService().share(context, reel);
  }

  void _openDetails(ReelTitle reel) {
    final item = reel.item;
    final imdbId = item.imdbId;
    if (imdbId == null || imdbId.isEmpty) return;
    MainPageBridge.requestCatalogDetailOpen(<String, dynamic>{
      'imdbId': imdbId,
      'type': item.type == 'series' ? 'series' : 'movie',
      'title': item.name,
      'year': int.tryParse(item.year ?? ''),
      'poster': item.poster,
      'originTab': MainTab.reels,
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_feed.available) {
      return const _ReelsMessage(
        icon: Icons.movie_filter_outlined,
        title: 'Reels needs TMDB metadata',
        body: 'Add the TMDB build token to discover official scene clips.',
      );
    }
    if (_items.isEmpty) {
      if (_error != null) {
        return _ReelsMessage(
          icon: Icons.cloud_off_rounded,
          title: 'Could not load Reels',
          body: _error!,
          action: _loadMore,
        );
      }
      return const Center(child: CircularProgressIndicator());
    }

    return ColoredBox(
      color: Colors.black,
      child: PageView.builder(
        controller: _controller,
        scrollDirection: Axis.vertical,
        itemCount: _items.length,
        onPageChanged: _onPageChanged,
        itemBuilder: (context, index) {
          final reel = _items[index];
          return _ReelPage(
            reel: reel,
            streams: _streams[reel.clipKey],
            active: index == _currentIndex,
            resolving: _resolving.contains(reel.clipKey),
            onDetails: () => _openDetails(reel),
            saved: _saved[_savedKey(reel)] ?? false,
            onSaved: () => _toggleSaved(reel),
            onShare: () => _share(reel),
          );
        },
      ),
    );
  }
}

class _ReelPage extends StatefulWidget {
  const _ReelPage({
    required this.reel,
    required this.streams,
    required this.active,
    required this.resolving,
    required this.onDetails,
    required this.saved,
    required this.onSaved,
    required this.onShare,
  });

  final ReelTitle reel;
  final YoutubeResolvedStreams? streams;
  final bool active;
  final bool resolving;
  final VoidCallback onDetails;
  final bool saved;
  final VoidCallback onSaved;
  final VoidCallback onShare;

  @override
  State<_ReelPage> createState() => _ReelPageState();
}

class _ReelPageState extends State<_ReelPage> {
  bool _muted = false;

  @override
  Widget build(BuildContext context) {
    final reel = widget.reel;
    final item = reel.item;
    final theme = AppThemeScope.of(context);
    final genres = (item.genres ?? const <String>[]).take(4).join(' • ');
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        HeroTrailerBackdrop(
          imageUrl: item.background ?? item.poster,
          videoUrl: widget.active ? widget.streams?.playUrl : null,
          audioUrl: widget.active ? widget.streams?.audioUrl : null,
          enabled: widget.active && widget.streams?.hasPlayable == true,
          sharpStill: true,
          imageBlurSigma: 0,
          videoBlurSigma: 0,
          startDelay: Duration.zero,
          ambientVolume: _muted ? 0 : 100,
          repeat: true,
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Color(0x12000000),
                Color(0x33000000),
                Color(0xF0000000),
              ],
              stops: <double>[0, 0.5, 1],
            ),
          ),
        ),
        SafeArea(
          child: Stack(
            children: <Widget>[
              Positioned(
                left: 20,
                top: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 7,
                  ),
                  decoration: GlassChrome.decoration(
                    theme,
                    radius: BorderRadius.circular(999),
                  ),
                  child: const Text(
                    'REELS',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 2.2,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 20,
                right: 92,
                bottom: 28,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (widget.resolving)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    GestureDetector(
                      onTap: widget.onDetails,
                      child: item.logo?.isNotEmpty == true
                          ? Image.network(
                              item.logo!,
                              height: 66,
                              width: 280,
                              fit: BoxFit.contain,
                              alignment: Alignment.bottomLeft,
                              errorBuilder: (_, _, _) =>
                                  _ReelTitle(name: item.name),
                            )
                          : _ReelTitle(name: item.name),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      <String>[
                        if (genres.isNotEmpty) genres,
                        reel.clipName,
                      ].join('  •  '),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 14,
                      ),
                    ),
                    OmdbRatingsBuilder(
                      imdbId: item.effectiveImdbId,
                      builder: (context, ratings) => Wrap(
                        spacing: 8,
                        children: omdbDetailReadouts(
                          ratings,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                          glyphColor: Colors.white,
                          glyphSize: 14,
                          gap: 8,
                          hasImdb: item.imdbRating != null,
                          imdbBadge: (value) =>
                              Text('IMDb ${value.toStringAsFixed(1)}'),
                        ),
                      ),
                    ),
                    if (item.description?.trim().isNotEmpty ==
                        true) ...<Widget>[
                      const SizedBox(height: 10),
                      _ReelSynopsis(text: item.description!.trim()),
                    ],
                  ],
                ),
              ),
              Positioned(
                right: 14,
                bottom: 28,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _ReelAction(
                      icon: _muted
                          ? Icons.volume_off_rounded
                          : Icons.volume_up_rounded,
                      label: _muted ? 'Unmute' : 'Sound',
                      onTap: () => setState(() => _muted = !_muted),
                    ),
                    const SizedBox(height: 16),
                    _ReelAction(
                      icon: widget.saved
                          ? Icons.check_rounded
                          : Icons.add_rounded,
                      label: widget.saved ? 'Saved' : 'Save',
                      selected: widget.saved,
                      onTap: widget.onSaved,
                    ),
                    const SizedBox(height: 16),
                    _ReelAction(
                      icon: Icons.ios_share_rounded,
                      label: 'Share',
                      onTap: widget.onShare,
                    ),
                    const SizedBox(height: 16),
                    _ReelAction(
                      icon: Icons.info_outline_rounded,
                      label: 'Details',
                      onTap: widget.onDetails,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ReelTitle extends StatelessWidget {
  const _ReelTitle({required this.name});
  final String name;
  @override
  Widget build(BuildContext context) => Text(
    name,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: const TextStyle(
      color: Colors.white,
      fontSize: 31,
      height: 1.02,
      letterSpacing: -0.8,
      fontWeight: FontWeight.w900,
      shadows: [Shadow(color: Colors.black87, blurRadius: 18)],
    ),
  );
}

class _ReelSynopsis extends StatefulWidget {
  const _ReelSynopsis({required this.text});
  final String text;
  @override
  State<_ReelSynopsis> createState() => _ReelSynopsisState();
}

class _ReelSynopsisState extends State<_ReelSynopsis> {
  bool open = false;
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: () => setState(() => open = !open),
    child: Text(
      widget.text,
      maxLines: open ? 8 : 3,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 14.5,
        height: 1.38,
        shadows: [Shadow(color: Colors.black87, blurRadius: 8)],
      ),
    ),
  );
}

class _ReelAction extends StatelessWidget {
  const _ReelAction({
    required this.icon,
    required this.label,
    required this.onTap,
    this.selected = false,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool selected;
  @override
  Widget build(BuildContext context) {
    final theme = AppThemeScope.of(context);
    return Column(
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            customBorder: const CircleBorder(),
            child: Ink(
              width: 50,
              height: 50,
              decoration: GlassChrome.decoration(
                theme,
                radius: BorderRadius.circular(25),
                active: selected,
                raised: true,
              ),
              child: Icon(icon, color: Colors.white, size: 25),
            ),
          ),
        ),
        const SizedBox(height: 5),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10.5,
            fontWeight: FontWeight.w700,
            shadows: [Shadow(color: Colors.black, blurRadius: 6)],
          ),
        ),
      ],
    );
  }
}

class _ReelsMessage extends StatelessWidget {
  const _ReelsMessage({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Future<void> Function()? action;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 48),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(body, textAlign: TextAlign.center),
            if (action != null) ...<Widget>[
              const SizedBox(height: 18),
              FilledButton(onPressed: action, child: const Text('Try again')),
            ],
          ],
        ),
      ),
    ),
  );
}
