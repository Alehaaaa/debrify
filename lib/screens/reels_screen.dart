import 'dart:async';

import 'package:flutter/material.dart';

import '../services/main_page_bridge.dart';
import '../services/reels_feed.dart';
import '../services/youtube_service.dart';
import '../widgets/hero_trailer_backdrop.dart';

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
    if (index >= _items.length - 3) unawaited(_loadMore());
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
          );
        },
      ),
    );
  }
}

class _ReelPage extends StatelessWidget {
  const _ReelPage({
    required this.reel,
    required this.streams,
    required this.active,
    required this.resolving,
    required this.onDetails,
  });

  final ReelTitle reel;
  final YoutubeResolvedStreams? streams;
  final bool active;
  final bool resolving;
  final VoidCallback onDetails;

  @override
  Widget build(BuildContext context) {
    final item = reel.item;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        HeroTrailerBackdrop(
          imageUrl: item.background ?? item.poster,
          videoUrl: active ? streams?.playUrl : null,
          audioUrl: active ? streams?.audioUrl : null,
          enabled: active && streams?.hasPlayable == true,
          sharpStill: true,
          imageBlurSigma: 0,
          videoBlurSigma: 0,
          startDelay: Duration.zero,
          ambientVolume: 100,
          repeat: true,
        ),
        const DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Color(0x22000000),
                Color(0x11000000),
                Color(0xDD000000),
              ],
              stops: <double>[0, 0.5, 1],
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 30),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text(
                  'Reels',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                if (resolving)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                Text(
                  item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    height: 1.05,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  <String>[
                    if (item.year?.isNotEmpty == true) item.year!,
                    if (item.imdbRating != null)
                      'IMDb ${item.imdbRating!.toStringAsFixed(1)}',
                    reel.clipName,
                  ].join('  •  '),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white70, fontSize: 14),
                ),
                if (item.description?.isNotEmpty == true) ...<Widget>[
                  const SizedBox(height: 10),
                  Text(
                    item.description!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      height: 1.35,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: item.imdbId == null ? null : onDetails,
                  icon: const Icon(Icons.info_outline_rounded),
                  label: const Text('More info'),
                ),
              ],
            ),
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
