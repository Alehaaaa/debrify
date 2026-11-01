import 'dart:async';
import 'package:flutter/material.dart';

import '../../models/metadata_preferences.dart';
import '../../models/stremio_addon.dart';
import '../../services/collection_focus_playback.dart';
import '../../services/imdb_trailer_service.dart';
import '../../services/metadata_preferences_service.dart';
import '../../services/metadata_provider_service.dart';
import '../../services/profiles/profile_runtime.dart';
import '../../services/stremio_service.dart';
import '../../services/youtube_service.dart';
import '../hero_trailer_backdrop.dart';

/// Mounted only after a focused card's dwell. Shares the ambient decoder lease
/// with the hero and releases it when focus leaves and this widget unmounts.
class SpotlightCardTrailer extends StatefulWidget {
  const SpotlightCardTrailer({
    super.key,
    required this.item,
    required this.volume,
    required this.onPlayingChanged,
    this.onToggleSound,
  });

  final StremioMeta item;
  final double volume;
  final ValueChanged<bool> onPlayingChanged;

  /// Off-TV: flip ambient sound from the speaker chip shown once the trailer
  /// is on screen. Null on TV/Search, where the chip is suppressed and sound
  /// is a Settings-only preference.
  final VoidCallback? onToggleSound;

  @override
  State<SpotlightCardTrailer> createState() => _SpotlightCardTrailerState();
}

class _SpotlightCardTrailerState extends State<SpotlightCardTrailer> {
  final _owner = Object();
  final Object? _scope = ProfileRuntime.scope.value;
  YoutubeResolvedStreams? _streams;
  bool _failed = false;
  bool _loading = true;
  bool _playing = false;
  Timer? _resolveTimeout;

  bool get _current => mounted && ProfileRuntime.scope.value == _scope;

  @override
  void initState() {
    super.initState();
    _resolveTimeout = Timer(const Duration(seconds: 20), () {
      if (mounted) setState(() { _failed = true; _loading = false; });
    });
    _resolve();
  }

  Future<void> _resolve() async {
    try {
      final item = widget.item;
      final prefs = await MetadataPreferencesService.loadForBackground(
        isCurrent: () => _current,
      );
      if (prefs == null || !_current) return;
      final imdb = item.effectiveImdbId;
      final candidates = await MetadataProviderService.instance.trailers(
        item,
        () async {
          if ((item.trailerYtId ?? '').isNotEmpty) return item.trailerYtId;
          if (imdb == null || !_current) return null;
          return (await StremioService.instance.fetchMetaDetails(
            imdbId: imdb,
            type: item.type,
          ))?.trailerYtId;
        },
        preferences: prefs,
      );
      if (!_current) return;
      final youtubeId = candidates.firstOrNull?.key;
      var streams = youtubeId == null
          ? null
          : await YoutubeService.resolveStreams(
              youtubeId,
              maxHeightOverride: 480,
              preferVp9: false,
            );
      if (!_current) return;
      if ((streams == null || !streams.hasPlayable) &&
          imdb != null &&
          (prefs.provider(MetadataCategory.trailers) ==
                  MetadataPreferences.current ||
              prefs.fallback)) {
        streams = await ImdbTrailerService.resolveTrailer(imdb, maxHeight: 480);
      }
      if (!_current || _failed || streams == null || !streams.hasPlayable) return;
      if (ModalRoute.of(context)?.isCurrent == false ||
          (WidgetsBinding.instance.lifecycleState != null &&
              WidgetsBinding.instance.lifecycleState !=
                  AppLifecycleState.resumed))
        return;
      // Notify competing ambient surfaces before mounting this decoder.
      CollectionFocusPlayback.claim(_owner);
      setState(() => _streams = streams);
    } catch (_) {
      // Artwork remains visible when the provider or stream is unavailable.
    } finally {
      _resolveTimeout?.cancel();
      if (mounted && _streams == null) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _resolveTimeout?.cancel();
    CollectionFocusPlayback.release(_owner);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final streams = _streams;
    if (!_current || _failed) return const SizedBox.shrink();
    // The speaker chip appears only once frames are live and the host wired a
    // toggle (off-TV). It sits ABOVE the IgnorePointer that holds the silent
    // video, so a tap flips sound instead of opening the title.
    final showToggle =
        streams != null && _playing && widget.onToggleSound != null;
    return Stack(fit: StackFit.expand, children: [
      IgnorePointer(
        child: Stack(fit: StackFit.expand, children: [
          if (streams != null) HeroTrailerBackdrop(
            imageUrl: null,
            videoUrl: streams.playUrl,
            audioUrl: streams.audioUrl,
            enabled: true,
            focusPreviewOwner: _owner,
            ambientVolume: widget.volume,
            imageBlurSigma: 0,
            videoBlurSigma: 0,
            startDelay: Duration.zero,
            firstFrameTimeout: const Duration(seconds: 12),
            onPlayingChanged: (playing) {
              if (mounted && (_playing != playing || (playing && _loading))) {
                setState(() {
                  if (playing) _loading = false;
                  _playing = playing;
                });
              }
              widget.onPlayingChanged(playing);
            },
            onPlaybackFailed: () {
              if (!mounted) return;
              setState(() {
                _failed = true;
                _playing = false;
              });
              CollectionFocusPlayback.release(_owner);
              widget.onPlayingChanged(false);
            },
          ),
          if (_loading)
            const Positioned(top: 12, left: 12, child: _TrailerLoadingDot()),
        ]),
      ),
      if (showToggle)
        Positioned(
          right: 10,
          bottom: 10,
          child: _SpotlightSoundToggle(
            muted: widget.volume <= 0,
            onTap: widget.onToggleSound!,
          ),
        ),
    ]);
  }
}

/// The playing reel card's speaker chip: a small translucent glass circle that
/// flips ambient trailer sound. Styled to sit quietly over artwork, matching
/// [_TrailerLoadingDot]'s self-contained treatment (no theme scope needed).
class _SpotlightSoundToggle extends StatelessWidget {
  const _SpotlightSoundToggle({required this.muted, required this.onTap});

  final bool muted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: muted ? 'Unmute trailer' : 'Mute trailer',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.46),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 6)],
          ),
          child: Icon(
            muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
            size: 18,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _TrailerLoadingDot extends StatefulWidget {
  const _TrailerLoadingDot();
  @override
  State<_TrailerLoadingDot> createState() => _TrailerLoadingDotState();
}

class _TrailerLoadingDotState extends State<_TrailerLoadingDot> with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 700), lowerBound: .3, upperBound: 1);
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
      _pulse.value = 1;
    } else {
      _pulse.repeat(reverse: true);
    }
  }
  @override
  void dispose() { _pulse.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => Semantics(label: 'Loading trailer', child: FadeTransition(
    opacity: _pulse,
    child: Container(width: 7, height: 7, decoration: const BoxDecoration(
      color: Colors.white, shape: BoxShape.circle,
      boxShadow: [BoxShadow(color: Colors.black54, blurRadius: 4)],
    )),
  ));
}
