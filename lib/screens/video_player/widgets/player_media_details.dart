import 'package:flutter/material.dart';
import '../../../models/play_loader_art.dart';
import '../../../models/stremio_addon.dart';
import '../../../widgets/home/spotlight_media_identity.dart';

@immutable
class PlayerMediaIdentity {
  const PlayerMediaIdentity({
    required this.title,
    this.imdbId,
    this.logo,
    this.synopsis,
    this.rating,
    this.episodeLabel,
    this.yearLabel,
    this.runtimeLabel,
    this.certificate,
    this.genreLabel,
  });

  final String title;
  final String? imdbId;
  final String? logo;
  final String? synopsis;
  final double? rating;
  final String? episodeLabel;
  final String? yearLabel;
  final String? runtimeLabel;
  final String? certificate;
  final String? genreLabel;

  static PlayerMediaIdentity fromMeta(
    StremioMeta? meta, {
    required String fallbackTitle,
    PlayLoaderArt? initialArt,
    String? fallbackImdbId,
    String? episodePlot,
    int? season,
    int? episode,
    String? episodeYear,
    String? episodeRuntime,
    bool useMetahubLogoFallback = false,
    bool requireEpisodePlot = false,
  }) {
    String? safe(String? value) =>
        value == null || value.trim().isEmpty ? null : value.trim();
    // The player episode guide's numeric `rating` can come from TVMaze or a
    // provider other than IMDb. Showing it inside an 'IMDb 8.0' badge was
    // falsely rebranding its provenance and contradicted the series detail
    // page's IMDb 7.7. Spotlight's IMDb badge only accepts the catalog's
    // explicitly supplied IMDb rating; unknown-source episode scores stay off.
    final raw =
        meta?.imdbRating ??
        double.tryParse(initialArt?.ratingLabel?.trim() ?? '');
    final imdb = meta?.effectiveImdbId ?? initialArt?.imdbId ?? fallbackImdbId;
    final fallbackLogo =
        useMetahubLogoFallback &&
            imdb != null &&
            RegExp(r'^tt\d+$').hasMatch(imdb)
        ? 'https://images.metahub.space/logo/medium/$imdb/img'
        : null;
    // Loader artwork sometimes contains a *derived* Metahub fallback. Do not
    // bypass the user's explicit artwork-provider + fallback OFF preference
    // simply because that image was carried into the player before fetch.
    final initialLogo = safe(initialArt?.logoUrl);
    final approvedInitialLogo =
        initialLogo != null &&
            initialLogo.startsWith('https://images.metahub.space/') &&
            !useMetahubLogoFallback
        ? null
        : initialLogo;
    return PlayerMediaIdentity(
      title: safe(meta?.name) ?? safe(fallbackTitle) ?? 'Now playing',
      imdbId: imdb,
      // The launching catalog already resolved this title's real identity.
      // Render it at route entry, not after the video decoder or meta fetch.
      logo: safe(meta?.logo) ?? approvedInitialLogo ?? fallbackLogo,
      synopsis:
          safe(episodePlot) ??
          (requireEpisodePlot
              ? null
              : safe(meta?.description) ?? safe(initialArt?.description)),
      rating: raw != null && raw.isFinite && raw > 0 && raw <= 10 ? raw : null,
      episodeLabel: season != null && episode != null
          ? 'Season $season · Episode $episode'
          : null,
      yearLabel:
          safe(episodeYear) ?? safe(meta?.year) ?? safe(initialArt?.yearLabel),
      runtimeLabel:
          safe(episodeRuntime) ??
          safe(meta?.runtimeDisplay) ??
          safe(initialArt?.runtimeLabel),
      certificate: safe(initialArt?.certificate),
      genreLabel:
          meta?.genres
              ?.where((genre) => genre.trim().isNotEmpty)
              .take(2)
              .join(' · ') ??
          safe(initialArt?.genreLabel),
    );
  }
}

/// Fits Home Spotlight's title treatment above the dock and subtitle band.
@immutable
class PlayerSpotlightPlacement {
  const PlayerSpotlightPlacement({
    required this.left,
    required this.width,
    required this.bottom,
    required this.maxHeight,
    required this.scale,
    required this.compact,
  });

  /// Aligns with the Home detail page's left gutter, not the player center.
  final double left;
  final double width;
  final double bottom;
  final double maxHeight;
  final double scale;
  final bool compact;

  factory PlayerSpotlightPlacement.forViewport({
    required Size viewport,
    required double dockHeight,
    required double bottomSafeArea,
    double leftSafeArea = 0,
    double rightSafeArea = 0,
  }) {
    final short = viewport.height < 510 || viewport.width < 510;
    final small = viewport.height < 350;
    final gutter = viewport.width >= 1300
        ? 72.0
        : viewport.width >= 760
        ? 42.0
        : 24.0;
    final left = (leftSafeArea + 12) > gutter ? leftSafeArea + 12 : gutter;
    final right = (rightSafeArea + 12) > gutter ? rightSafeArea + 12 : gutter;
    final bottom =
        dockHeight +
        bottomSafeArea +
        (small
            ? 20.0
            : short
            ? 48.0
            : 108.0);
    return PlayerSpotlightPlacement(
      left: left,
      width: (viewport.width - left - right).clamp(
        0.0,
        viewport.width >= 760 ? 560.0 : 480.0,
      ),
      bottom: bottom,
      maxHeight: (viewport.height - bottom - (small ? 10 : 28)).clamp(
        36.0,
        viewport.height,
      ),
      scale: small
          ? 0.72
          : short
          ? 0.82
          : 1.0,
      compact: short,
    );
  }
}

abstract final class PlayerCreditsPolicy {
  /// An absent Next button alone does not prove a series has ended: a lookup
  /// can still be pending or its guide missing. Only a guide containing the
  /// current episode and confirming no successor admits related titles.
  static bool canSuggestAfterSeriesFinale({
    required bool guideContainsCurrent,
    required bool hasActualNext,
  }) => guideContainsCurrent && !hasActualNext;

  static bool canReconcileMovie({
    required bool isMovie,
    required bool hasIdentity,
    required bool hasQueue,
    required bool isLive,
    required bool validating,
  }) => isMovie && hasIdentity && !hasQueue && !isLive && !validating;

  static bool reachedCompletionThreshold(
    Duration position,
    Duration duration,
    int thresholdPercent,
  ) =>
      duration > Duration.zero &&
      position > Duration.zero &&
      thresholdPercent > 0 &&
      position.inMicroseconds * 100 >=
          duration.inMicroseconds * thresholdPercent;

  static bool atCredits(Duration position, Duration duration) =>
      duration.inSeconds >= 240 &&
      position > Duration.zero &&
      duration - position <= const Duration(minutes: 7) &&
      position.inMilliseconds >= duration.inMilliseconds * 0.88;

  static bool shouldAutoReturnMovie({
    required bool isMovie,
    required bool hasQueue,
    required bool hasNext,
    required bool isLive,
    required bool isPip,
    required bool sleepStopped,
  }) => isMovie && !hasQueue && !hasNext && !isLive && !isPip && !sleepStopped;

  static List<StremioMeta> unwatchedRecommendations(
    StremioMeta current,
    Iterable<StremioMeta> suggestions,
    Set<String> watchedIds, {
    int limit = 3,
  }) {
    final seen = <String>{current.imdbId ?? current.id};
    final result = <StremioMeta>[];
    for (final item in suggestions) {
      final id = item.imdbId ?? item.id;
      if (id.isEmpty || !seen.add(id) || watchedIds.contains(id)) continue;
      if (item.type != 'movie' && item.type != 'series') continue;
      result.add(item);
      if (result.length >= limit) break;
    }
    return result;
  }
}

/// Noninteractive details are displayed only with visible controls, leaving
/// the bottom timeline, subtitle band and video title unobscured.
class PlayerMediaDetails extends StatelessWidget {
  const PlayerMediaDetails({
    super.key,
    required this.media,
    this.compact = false,
    this.scale = 1,
    this.logoScale,
  });
  final PlayerMediaIdentity media;

  /// Landscape phone / constrained player: keep the timeline and subtitles
  /// clear by collapsing the longer description, not squeezing the text.
  final bool compact;
  final double scale;
  final double? logoScale;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: SpotlightMediaIdentity(
      key: const ValueKey('player-spotlight-identity'),
      title: media.title,
      imdbId: media.imdbId,
      logoUrl: media.logo,
      episodeLabel: media.episodeLabel,
      ratingLabel: media.rating?.toString(),
      yearLabel: media.yearLabel,
      runtimeLabel: media.runtimeLabel,
      certificate: media.certificate,
      genreLabel: media.genreLabel,
      description: media.synopsis,
      scale: scale,
      logoScale: logoScale,
      compact: compact,
    ),
  );
}

/// A compact opt-in panel: it never obscures the credit roll with a full
/// screen takeover, fake artwork, or automatic playback.
class PlayerCreditsSuggestions extends StatelessWidget {
  const PlayerCreditsSuggestions({
    super.key,
    required this.items,
    required this.onSelect,
    this.onNextEpisode,
  });
  final List<StremioMeta> items;
  final ValueChanged<StremioMeta> onSelect;
  final VoidCallback? onNextEpisode;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty && onNextEpisode == null) {
      return const SizedBox.shrink();
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white24),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Up next',
                style: TextStyle(
                  color: Colors.white70,
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                ),
              ),
              if (onNextEpisode != null)
                TextButton.icon(
                  key: const ValueKey('player-credits-next-episode'),
                  onPressed: onNextEpisode,
                  icon: const Icon(Icons.skip_next_rounded, size: 18),
                  label: const Text('Next episode'),
                ),
              for (final item in items)
                TextButton(
                  key: ValueKey('player-credits-recommendation-${item.id}'),
                  onPressed: () => onSelect(item),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      item.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
