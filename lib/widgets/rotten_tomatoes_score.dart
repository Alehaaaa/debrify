import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/omdb/omdb_ratings_service.dart';
import '../theme/app_theme_scope.dart';

/// Lets a tile's State show a Rotten Tomatoes score: call
/// [rottenTomatoesFor] from `build` with the title's IMDb id. The first call
/// for an id subscribes (and fetches, if the device cache is cold or stale);
/// the tile rebuilds once when the score lands. Switching ids — a recycled
/// tile — drops the old subscription, so it never shows another title's score.
mixin RottenTomatoesScoreMixin<T extends StatefulWidget> on State<T> {
  String? _rtId;

  @protected
  OmdbRatingsService get rottenTomatoesService => OmdbRatingsService.instance;

  int? rottenTomatoesFor(String? imdbId) => omdbRatingsFor(imdbId)?.score;

  /// Every OMDb rating for [imdbId] (RT, Metacritic, IMDb), or null.
  OmdbCacheEntry? omdbRatingsFor(String? imdbId) {
    final service = rottenTomatoesService;
    final id = service.enabled && OmdbRatingsService.isImdbId(imdbId)
        ? imdbId
        : null;
    if (id != _rtId) {
      if (_rtId != null) service.removeListener(_rtId!, _rtChanged);
      _rtId = id;
      if (id != null) service.addListener(id, _rtChanged);
    }
    return id == null ? null : service.ratingsFor(id);
  }

  void _rtChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    if (_rtId != null) {
      rottenTomatoesService.removeListener(_rtId!, _rtChanged);
      _rtId = null;
    }
    super.dispose();
  }
}

/// The caption meta line ("2024 · ★ 8.1") with the Tomatometer appended as
/// the flat tomato glyph + "92%", in the line's own colour and size — the
/// glyph is the tomato's equivalent of the "★" text glyph.
InlineSpan ratingsMetaSpan(
  String meta,
  int? tomatoes, {
  required double fontSize,
  required Color color,
}) {
  if (tomatoes == null) return TextSpan(text: meta);
  return TextSpan(
    children: [
      if (meta.isNotEmpty) TextSpan(text: '$meta · '),
      WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: TomatoGlyph(size: fontSize * 0.95, color: color),
      ),
      TextSpan(text: ' $tomatoes%'),
    ],
  );
}

/// A flat, single-colour tomato (round body, five-point calyx and stem) —
/// drawn rather than an emoji so it is monochrome and tints like "★".
class TomatoGlyph extends StatelessWidget {
  final double size;
  final Color color;
  const TomatoGlyph({super.key, required this.size, required this.color});

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _TomatoPainter(color)),
  );
}

class _TomatoPainter extends CustomPainter {
  final Color color;
  _TomatoPainter(this.color);

  /// The silhouette in a 24×24 box; built once and scaled per paint.
  static final Path _unit = _build();

  static Path _star(double cx, double cy, double outer, double inner) {
    final path = Path();
    for (var i = 0; i < 10; i++) {
      final r = i.isEven ? outer : inner;
      // Point 0 straight down; the flattened crown sits on the shoulders.
      final a = math.pi / 2 + i * math.pi / 5;
      final x = cx + r * math.cos(a);
      final y = cy + r * math.sin(a) * 0.5;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    return path..close();
  }

  static Path _build() {
    final body = Path()
      ..addOval(Rect.fromCenter(center: const Offset(12, 14.4), width: 22, height: 17.2));
    final calyx = _star(12, 6.6, 7.6, 2.4);
    final gap = _star(12, 6.6, 9.0, 3.5);
    final stem = Path()
      ..addRRect(RRect.fromRectAndRadius(
        const Rect.fromLTWH(11.1, 1.0, 1.8, 6.4),
        const Radius.circular(0.9),
      ));
    final cut = Path.combine(PathOperation.difference, body, gap);
    return Path.combine(
      PathOperation.union,
      Path.combine(PathOperation.union, cut, calyx),
      stem,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / 24;
    canvas.save();
    canvas.scale(s);
    canvas.drawPath(_unit, Paint()..color = color..isAntiAlias = true);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TomatoPainter old) => old.color != color;
}

/// Glass chip twin of the tile's ★ chip: flat white tomato + "92%".
class RottenTomatoesChip extends StatelessWidget {
  final int score;
  const RottenTomatoesChip({super.key, required this.score});

  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    return Container(
      key: const ValueKey('rotten-tomatoes-chip'),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: app.shape.br(6),
        border: Border.all(color: app.fade(app.onGlass, 0.18), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const TomatoGlyph(size: 11, color: Colors.white),
          const SizedBox(width: 3),
          Text(
            '$score%',
            style: TextStyle(
              color: app.core.tx,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// Flat, single-colour Metascore mark: a disc with an "m" cut out — the Metacritic counterpart of [TomatoGlyph].
class MetacriticGlyph extends StatelessWidget {
  final double size;
  final Color color;
  const MetacriticGlyph({super.key, required this.size, required this.color});

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _MetacriticPainter(color)),
  );
}

class _MetacriticPainter extends CustomPainter {
  final Color color;
  _MetacriticPainter(this.color);

  static final Path _unit = () {
    final disc = Path()
      ..addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 11));
    // A bold "m": three stems under a rounded cap, knocked out of the disc.
    final m = Path()
      ..addRRect(RRect.fromRectAndRadius(
        const Rect.fromLTWH(6.0, 7.6, 12.0, 4.2),
        const Radius.circular(2.1),
      ))
      ..addRect(const Rect.fromLTWH(6.0, 9.6, 2.4, 7.4))
      ..addRect(const Rect.fromLTWH(10.8, 9.6, 2.4, 7.4))
      ..addRect(const Rect.fromLTWH(15.6, 9.6, 2.4, 7.4));
    return Path.combine(PathOperation.difference, disc, m);
  }();

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.shortestSide / 24);
    canvas.drawPath(_unit, Paint()..color = color..isAntiAlias = true);
    canvas.restore();
  }

  @override
  bool shouldRepaint(_MetacriticPainter old) => old.color != color;
}

/// Rebuilds [builder] with every OMDb rating for [imdbId] once they arrive
/// (null until then, or with no key / a non-IMDb id). For detail pages,
/// which lay the scores out in their own style next to IMDb's.
class OmdbRatingsBuilder extends StatefulWidget {
  final String? imdbId;
  final Widget Function(BuildContext context, OmdbCacheEntry? ratings) builder;
  const OmdbRatingsBuilder({
    super.key,
    required this.imdbId,
    required this.builder,
  });

  @override
  State<OmdbRatingsBuilder> createState() => _OmdbRatingsBuilderState();
}

class _OmdbRatingsBuilderState extends State<OmdbRatingsBuilder>
    with RottenTomatoesScoreMixin<OmdbRatingsBuilder> {
  @override
  Widget build(BuildContext context) =>
      widget.builder(context, omdbRatingsFor(widget.imdbId));
}

/// "value + mark" readouts in the detail meta bars' grammar ("8.1 [IMDb]"):
/// RT and Metacritic as "89% 🍅" / "82 Ⓜ", each preceded by [gap], and
/// IMDb from OMDb only when the page has no IMDb rating of its own
/// ([imdbBadge] draws it in the page's existing style).
List<Widget> omdbDetailReadouts(
  OmdbCacheEntry? r, {
  required TextStyle style,
  required Color glyphColor,
  required double glyphSize,
  required double gap,
  bool hasImdb = true,
  Widget Function(double rating)? imdbBadge,
}) {
  if (r == null) return const [];
  Widget pair(String value, Widget glyph, String key) => Row(
    key: ValueKey('omdb-$key'),
    mainAxisSize: MainAxisSize.min,
    children: [Text(value, style: style), const SizedBox(width: 5), glyph],
  );
  return [
    if (!hasImdb && r.imdb != null && imdbBadge != null) ...[
      SizedBox(width: gap),
      imdbBadge(r.imdb!),
    ],
    if (r.score != null) ...[
      SizedBox(width: gap),
      pair(
        '${r.score}%',
        TomatoGlyph(size: glyphSize, color: glyphColor),
        'rt',
      ),
    ],
    if (r.metacritic != null) ...[
      SizedBox(width: gap),
      pair(
        '${r.metacritic}',
        MetacriticGlyph(size: glyphSize, color: glyphColor),
        'mc',
      ),
    ],
  ];
}
