import 'package:flutter/material.dart';

import '../../services/imdb_enrichment_service.dart';
import '../../services/omdb/omdb_ratings_service.dart';
import '../rotten_tomatoes_score.dart';

/// Ratings, critic scores and real IMDb lists belong to the SAME identity
/// block on Home, Details, Prepare and Player. This is intentionally not a
/// floating auxiliary detail row. Missing/unverified values draw nothing.
class SpotlightEditorialSignals extends StatefulWidget {
  const SpotlightEditorialSignals({
    super.key,
    this.imdbId,
    this.imdbRating,
    this.enrichment,
    this.debugRatings,
    this.scale = 1,
    this.compact = false,
  });

  final String? imdbId;
  final String? imdbRating;
  final ImdbEnrichment? enrichment;

  /// A deterministic widget-test seam; production always uses real OMDb.
  @visibleForTesting
  final OmdbCacheEntry? debugRatings;
  final double scale;
  final bool compact;

  static String? validRating(String? raw) {
    final parsed = double.tryParse(raw?.trim() ?? '');
    if (parsed == null || !parsed.isFinite || parsed <= 0 || parsed > 10) {
      return null;
    }
    return parsed.toStringAsFixed(1);
  }

  @override
  State<SpotlightEditorialSignals> createState() =>
      _SpotlightEditorialSignalsState();
}

class _SpotlightEditorialSignalsState extends State<SpotlightEditorialSignals> {
  static final Map<String, Future<ImdbEnrichment?>> _pending = {};
  Future<ImdbEnrichment?>? _enrichment;

  String? get _id =>
      OmdbRatingsService.isImdbId(widget.imdbId) ? widget.imdbId : null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant SpotlightEditorialSignals oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imdbId != widget.imdbId ||
        oldWidget.enrichment != widget.enrichment) {
      _load();
    }
  }

  void _load() {
    final id = _id;
    if (id == null || widget.enrichment != null) {
      _enrichment = null;
      return;
    }
    // IMDb's full enrichment also powers Showcase detail. Reuse that source;
    // coalesce simultaneously mounted Home/loader/player requests per IMDb ID.
    // A failed request is removable and can retry on a later presentation.
    _enrichment = _pending.putIfAbsent(id, () {
      final future = ImdbEnrichmentService.fetch(id);
      future.whenComplete(() {
        if (identical(_pending[id], future)) _pending.remove(id);
      });
      return future;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.debugRatings != null) {
      return _signals(widget.enrichment, widget.debugRatings);
    }
    return OmdbRatingsBuilder(
      imdbId: _id,
      builder: (context, ratings) => FutureBuilder<ImdbEnrichment?>(
        future: _enrichment,
        builder: (context, snapshot) =>
            _signals(widget.enrichment ?? snapshot.data, ratings),
      ),
    );
  }

  Widget _signals(ImdbEnrichment? imdb, OmdbCacheEntry? omdb) {
    final k = widget.scale.clamp(0.65, 1.8).toDouble();
    final rating =
        SpotlightEditorialSignals.validRating(widget.imdbRating) ??
        SpotlightEditorialSignals.validRating(imdb?.rating?.toString()) ??
        SpotlightEditorialSignals.validRating(omdb?.imdb?.toString());
    // Showcase already receives IMDb GraphQL enrichment even when the user
    // has not configured an OMDb API key. Preserve that verified Metascore
    // rather than silently dropping its chip on the other surfaces.
    final metascore = omdb?.metacritic ?? imdb?.metacriticScore;
    final chips = <Widget>[
      if (rating != null)
        SpotlightOutlinedSignal(
          key: const ValueKey('spotlight-media-rating'),
          label: '★ $rating',
          accessibilityLabel: 'IMDb $rating',
          scale: k,
        ),
      if (omdb?.score != null && omdb!.score! >= 0 && omdb.score! <= 100)
        SpotlightOutlinedSignal(
          key: const ValueKey('spotlight-media-rotten-tomatoes'),
          label: '${omdb.score}%',
          glyph: TomatoGlyph(size: 9 * k, color: Colors.white),
          accessibilityLabel: 'Rotten Tomatoes ${omdb.score}%',
          scale: k,
        ),
      if (metascore != null && metascore >= 0 && metascore <= 100)
        SpotlightOutlinedSignal(
          key: const ValueKey('spotlight-media-metacritic'),
          label: '$metascore',
          glyph: MetacriticGlyph(size: 9 * k, color: Colors.white),
          accessibilityLabel: 'Metacritic $metascore',
          scale: k,
        ),
      if (imdb?.top250Rank != null &&
          imdb!.top250Rank! > 0 &&
          imdb.top250Rank! <= 250)
        SpotlightOutlinedSignal(
          key: const ValueKey('spotlight-media-imdb-top250'),
          label: 'IMDb TOP 250  №${imdb.top250Rank}',
          accessibilityLabel: 'IMDb Top 250 position ${imdb.top250Rank}',
          scale: k,
          editorial: true,
        ),
      if (imdb?.meterRank != null && imdb!.meterRank! > 0)
        SpotlightOutlinedSignal(
          key: const ValueKey('spotlight-media-trending'),
          label:
              'TRENDING  №${imdb.meterRank}${switch (imdb.meterDelta) {
                null || 0 => '',
                final delta when delta > 0 => '  ▴$delta',
                final delta => '  ▾${-delta}',
              }}',
          accessibilityLabel: 'IMDb trending rank ${imdb.meterRank}',
          scale: k,
          editorial: true,
        ),
    ];
    if (chips.isEmpty) return const SizedBox.shrink();
    return Wrap(
      key: const ValueKey('spotlight-media-signals'),
      spacing: 5 * k,
      runSpacing: 5 * k,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: chips,
    );
  }
}

/// Showcase's original hairline rectangle, now owned by the common media
/// identity. No solid yellow pill or detached rank banner on any surface.
class SpotlightOutlinedSignal extends StatelessWidget {
  const SpotlightOutlinedSignal({
    super.key,
    required this.label,
    this.accessibilityLabel,
    this.glyph,
    this.scale = 1,
    this.editorial = false,
  });

  final String label;
  final String? accessibilityLabel;
  final Widget? glyph;
  final double scale;
  final bool editorial;

  @override
  Widget build(BuildContext context) => Semantics(
    label: accessibilityLabel ?? label,
    excludeSemantics: true,
    child: Container(
      decoration: BoxDecoration(
        border: Border.all(
          width: 0.75,
          color: Colors.white.withValues(alpha: editorial ? 0.32 : 0.45),
        ),
        borderRadius: BorderRadius.circular((editorial ? 4 : 2.5) * scale),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: (editorial ? 6 : 4) * scale,
        vertical: (editorial ? 2.5 : 1) * scale,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (glyph != null) ...[glyph!, SizedBox(width: 3 * scale)],
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.91),
              fontSize: (editorial ? 8 : 9) * scale,
              fontWeight: editorial ? FontWeight.w700 : FontWeight.w500,
              letterSpacing: editorial ? 0.35 : 0,
              height: 1.28,
            ),
          ),
        ],
      ),
    ),
  );
}
