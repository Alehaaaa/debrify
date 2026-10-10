import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Liquid glass for the Glass player controls and the trailer chrome.
///
/// Every number lives in `assets/design/glass_tokens.json` — blur, tint,
/// saturation, radii, the specular rim — and is read through [GlassTokens].
/// Surfaces pick one of three [GlassVariant]s:
///
///  * [GlassVariant.frosted]     — subtle tint, high blur. Sheets and menus.
///  * [GlassVariant.translucent] — low blur, strong background. Small buttons
///    that must read on any frame.
///  * [GlassVariant.dynamic]     — follows the brightness of what is behind
///    it ([GlassBrightnessScope]): clear and saturated over dark scenes,
///    denser and darker over bright ones so white controls stay legible.
///
/// The "liquid" part is what plain frosted glass lacks: the backdrop is
/// saturated as well as blurred (colour seems to pool in the glass), a top
/// sheen catches light, and a gradient rim gives a bright specular edge at
/// the top-left fading to a faint one at the bottom-right.
enum GlassVariant { frosted, translucent, dynamic }

/// One resolved look: what a [GlassSurface] actually paints.
@immutable
class GlassLook {
  /// Gaussian sigma, logical pixels.
  final double blur;

  /// Saturation multiplier applied to the backdrop (1 = unchanged).
  final double saturation;

  /// Light layer over the backdrop.
  final Color tint;

  /// Dark layer under the tint — what keeps white content legible.
  final Color shade;

  const GlassLook({
    required this.blur,
    required this.saturation,
    required this.tint,
    required this.shade,
  });

  factory GlassLook.fromJson(Map<String, dynamic> j) => GlassLook(
    blur: (j['blur'] as num).toDouble(),
    saturation: (j['saturation'] as num).toDouble(),
    tint: _hex(j['tint'] as String),
    shade: _hex(j['shade'] as String),
  );

  static GlassLook lerp(GlassLook a, GlassLook b, double t) => GlassLook(
    blur: ui.lerpDouble(a.blur, b.blur, t)!,
    saturation: ui.lerpDouble(a.saturation, b.saturation, t)!,
    tint: Color.lerp(a.tint, b.tint, t)!,
    shade: Color.lerp(a.shade, b.shade, t)!,
  );

  String get _sig => '$blur/$saturation/${_argb(tint)}/${_argb(shade)}';
}

/// The design tokens. [current] starts as the compiled [defaults] (identical
/// to the JSON, enforced by `test/glass_tokens_test.dart`) and is replaced by
/// the asset once [load] completes, so a surface never waits on I/O.
@immutable
class GlassTokens {
  final double radiusPanel;
  final double radiusPanelCompact;
  final double radiusSheet;
  final double rimWidth;
  final Color rimHighlight;
  final Color rimMid;
  final Color rimLowlight;
  final Color sheen;
  final Color shadowColor;
  final double shadowBlur;
  final double shadowOffsetY;
  final GlassLook frosted;
  final GlassLook translucent;
  final GlassLook dynamicDim;
  final GlassLook dynamicBright;
  final double defaultBrightness;
  final Duration transition;
  final Color reducedTransparencyShade;

  const GlassTokens({
    required this.radiusPanel,
    required this.radiusPanelCompact,
    required this.radiusSheet,
    required this.rimWidth,
    required this.rimHighlight,
    required this.rimMid,
    required this.rimLowlight,
    required this.sheen,
    required this.shadowColor,
    required this.shadowBlur,
    required this.shadowOffsetY,
    required this.frosted,
    required this.translucent,
    required this.dynamicDim,
    required this.dynamicBright,
    required this.defaultBrightness,
    required this.transition,
    required this.reducedTransparencyShade,
  });

  static const String asset = 'assets/design/glass_tokens.json';

  static const GlassTokens defaults = GlassTokens(
    radiusPanel: 24,
    radiusPanelCompact: 20,
    radiusSheet: 26,
    rimWidth: 1.0,
    rimHighlight: Color(0x8CFFFFFF),
    rimMid: Color(0x12FFFFFF),
    rimLowlight: Color(0x33FFFFFF),
    sheen: Color(0x26FFFFFF),
    shadowColor: Color(0x33000000),
    shadowBlur: 36,
    shadowOffsetY: 14,
    frosted: GlassLook(
      blur: 24,
      saturation: 1.8,
      tint: Color(0x14FFFFFF),
      shade: Color(0x29000000),
    ),
    translucent: GlassLook(
      blur: 6,
      saturation: 1.25,
      tint: Color(0x0DFFFFFF),
      shade: Color(0x8C0E0E12),
    ),
    dynamicDim: GlassLook(
      blur: 20,
      saturation: 1.7,
      tint: Color(0x1AFFFFFF),
      shade: Color(0x1A000000),
    ),
    dynamicBright: GlassLook(
      blur: 28,
      saturation: 1.15,
      tint: Color(0x0AFFFFFF),
      shade: Color(0x6B000000),
    ),
    defaultBrightness: 0.35,
    transition: Duration(milliseconds: 400),
    reducedTransparencyShade: Color(0xE6141418),
  );

  factory GlassTokens.fromJson(Map<String, dynamic> j) {
    final radius = j['radius'] as Map<String, dynamic>;
    final rim = j['rim'] as Map<String, dynamic>;
    final shadow = j['shadow'] as Map<String, dynamic>;
    final variants = j['variants'] as Map<String, dynamic>;
    final dyn = variants['dynamic'] as Map<String, dynamic>;
    final dynCfg = j['dynamic'] as Map<String, dynamic>;
    final reduced = j['reducedTransparency'] as Map<String, dynamic>;
    return GlassTokens(
      radiusPanel: (radius['panel'] as num).toDouble(),
      radiusPanelCompact: (radius['panelCompact'] as num).toDouble(),
      radiusSheet: (radius['sheet'] as num).toDouble(),
      rimWidth: (rim['width'] as num).toDouble(),
      rimHighlight: _hex(rim['highlight'] as String),
      rimMid: _hex(rim['mid'] as String),
      rimLowlight: _hex(rim['lowlight'] as String),
      sheen: _hex(j['sheen'] as String),
      shadowColor: _hex(shadow['color'] as String),
      shadowBlur: (shadow['blur'] as num).toDouble(),
      shadowOffsetY: (shadow['offsetY'] as num).toDouble(),
      frosted: GlassLook.fromJson(variants['frosted'] as Map<String, dynamic>),
      translucent: GlassLook.fromJson(
        variants['translucent'] as Map<String, dynamic>,
      ),
      dynamicDim: GlassLook.fromJson(dyn),
      dynamicBright: GlassLook.fromJson(dyn['bright'] as Map<String, dynamic>),
      defaultBrightness: (dynCfg['defaultBrightness'] as num).toDouble(),
      transition: Duration(milliseconds: dynCfg['transitionMs'] as int),
      reducedTransparencyShade: _hex(reduced['shade'] as String),
    );
  }

  /// The tokens surfaces read. Never null; see [load].
  static GlassTokens current = defaults;
  static Future<void>? _loading;

  /// Reads the JSON asset once per process. Safe to call repeatedly; a
  /// missing or malformed asset keeps [defaults].
  static Future<void> load() => _loading ??= () async {
    try {
      final raw = await rootBundle.loadString(asset);
      current = GlassTokens.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (e) {
      debugPrint('GlassTokens: keeping compiled defaults ($e)');
    }
  }();

  /// The look for [variant]. [brightness] (0 = black frame, 1 = white) only
  /// matters for [GlassVariant.dynamic].
  GlassLook look(GlassVariant variant, double brightness) => switch (variant) {
    GlassVariant.frosted => frosted,
    GlassVariant.translucent => translucent,
    // Dark scenes keep the clear, saturated look; anything past ~70% luma
    // gets the dense one. The middle eases between them.
    GlassVariant.dynamic => GlassLook.lerp(
      dynamicDim,
      dynamicBright,
      Curves.easeInOut.transform(((brightness - 0.25) / 0.45).clamp(0.0, 1.0)),
    ),
  };

  /// Every value, for the drift test.
  @visibleForTesting
  String get signature => [
    radiusPanel,
    radiusPanelCompact,
    radiusSheet,
    rimWidth,
    _argb(rimHighlight),
    _argb(rimMid),
    _argb(rimLowlight),
    _argb(sheen),
    _argb(shadowColor),
    shadowBlur,
    shadowOffsetY,
    frosted._sig,
    translucent._sig,
    dynamicDim._sig,
    dynamicBright._sig,
    defaultBrightness,
    transition.inMilliseconds,
    _argb(reducedTransparencyShade),
  ].join('|');
}

Color _hex(String s) => Color(int.parse(s.replaceFirst('#', ''), radix: 16));
int _argb(Color c) => c.toARGB32();

/// Publishes the brightness behind dynamic glass to the surfaces below it.
class GlassBrightnessScope extends InheritedNotifier<ValueListenable<double>> {
  const GlassBrightnessScope({
    super.key,
    required ValueListenable<double> brightness,
    required super.child,
  }) : super(notifier: brightness);

  /// Null when no scope is above — dynamic glass then uses the token default.
  static double? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<GlassBrightnessScope>()
      ?.notifier
      ?.value;
}

/// A piece of liquid glass.
class GlassSurface extends StatelessWidget {
  final Widget child;
  final BorderRadius radius;
  final EdgeInsetsGeometry padding;
  final GlassVariant variant;

  /// A brighter sheen — for the primary play button.
  final bool strong;

  /// Scales the drop shadow: 1 for panels, less for small buttons, whose
  /// shadow would otherwise sit far below them.
  final double shadowScale;

  const GlassSurface({
    super.key,
    required this.child,
    required this.radius,
    this.padding = EdgeInsets.zero,
    this.variant = GlassVariant.frosted,
    this.strong = false,
    this.shadowScale = 1,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.current;
    if (variant != GlassVariant.dynamic) {
      return _paint(context, tokens, tokens.look(variant, 0));
    }
    final brightness =
        GlassBrightnessScope.of(context) ?? tokens.defaultBrightness;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: brightness),
      duration: tokens.transition,
      curve: Curves.easeOut,
      builder: (context, b, _) =>
          _paint(context, tokens, tokens.look(variant, b)),
    );
  }

  Widget _paint(BuildContext context, GlassTokens t, GlassLook look) {
    // "Reduce transparency" / high contrast: a solid, legible plate, no blur.
    final reduced = MediaQuery.maybeHighContrastOf(context) ?? false;
    final sheen = strong
        ? t.sheen.withValues(alpha: (t.sheen.a * 1.8).clamp(0.0, 1.0))
        : t.sheen;
    final tintTop = Color.alphaBlend(sheen, look.tint);

    Widget body = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        color: reduced ? t.reducedTransparencyShade : look.shade,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [tintTop, look.tint, look.tint],
            stops: const [0.0, 0.5, 1.0],
          ),
        ),
        child: CustomPaint(
          foregroundPainter: _RimPainter(radius: radius, tokens: t),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );

    if (!reduced && look.blur > 0) {
      final filter = ui.ImageFilter.compose(
        outer: ColorFilter.matrix(_saturation(look.saturation)),
        inner: ui.ImageFilter.blur(sigmaX: look.blur, sigmaY: look.blur),
      );
      // Inside a BackdropGroup the surfaces share one backdrop read, which is
      // what keeps several glass pieces on screen affordable.
      body = BackdropGroup.of(context) != null
          ? BackdropFilter.grouped(filter: filter, child: body)
          : BackdropFilter(filter: filter, child: body);
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [
          BoxShadow(
            color: t.shadowColor,
            blurRadius: t.shadowBlur * shadowScale,
            spreadRadius: -6 * shadowScale,
            offset: Offset(0, t.shadowOffsetY * shadowScale),
          ),
        ],
      ),
      child: ClipRRect(borderRadius: radius, child: body),
    );
  }

  /// Luminance-preserving saturation matrix (Rec. 709 weights).
  static List<double> _saturation(double s) {
    const r = 0.2126, g = 0.7152, b = 0.0722;
    final i = 1 - s;
    return [
      r * i + s, g * i, b * i, 0, 0, //
      r * i, g * i + s, b * i, 0, 0, //
      r * i, g * i, b * i + s, 0, 0, //
      0, 0, 0, 1, 0,
    ];
  }
}

/// The specular edge: bright where light would catch the top-left, nearly
/// gone along the sides, a faint return at the bottom-right.
class _RimPainter extends CustomPainter {
  final BorderRadius radius;
  final GlassTokens tokens;
  const _RimPainter({required this.radius, required this.tokens});

  @override
  void paint(Canvas canvas, Size size) {
    final w = tokens.rimWidth;
    final rect = Offset.zero & size;
    final rrect = radius.toRRect(rect).deflate(w / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          tokens.rimHighlight,
          tokens.rimMid,
          tokens.rimMid,
          tokens.rimLowlight,
        ],
        stops: const [0.0, 0.35, 0.7, 1.0],
      ).createShader(rect);
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(_RimPainter old) =>
      old.radius != radius || !identical(old.tokens, tokens);
}

/// Samples how bright the picture is, for [GlassVariant.dynamic].
///
/// Runs only while [setActive] is on (the player turns it on while its
/// controls are visible): one frame grab right away, then one every
/// [interval]. The grab is shrunk to a 32 px thumbnail before averaging, so
/// the cost is the capture itself, not the maths.
class GlassBrightnessProbe {
  GlassBrightnessProbe({
    required this.capture,
    this.interval = const Duration(seconds: 4),
  });

  /// Returns an encoded frame (JPEG/PNG) or null when none is available.
  final Future<Uint8List?> Function() capture;
  final Duration interval;

  final ValueNotifier<double> brightness = ValueNotifier<double>(
    GlassTokens.current.defaultBrightness,
  );

  Timer? _timer;
  bool _busy = false;
  bool _disposed = false;

  void setActive(bool active) {
    if (_disposed) return;
    if (active && _timer == null) {
      unawaited(_sample());
      _timer = Timer.periodic(interval, (_) => unawaited(_sample()));
    } else if (!active) {
      _timer?.cancel();
      _timer = null;
    }
  }

  Future<void> _sample() async {
    if (_busy || _disposed) return;
    _busy = true;
    try {
      final bytes = await capture().timeout(const Duration(seconds: 3));
      if (bytes == null || bytes.isEmpty || _disposed) return;
      final luma = await lumaOf(bytes);
      if (luma != null && !_disposed) brightness.value = luma;
    } catch (_) {
      // No frame yet, a disposed player, an unsupported backend: keep the
      // last value. Brightness is a nicety, never worth an error.
    } finally {
      _busy = false;
    }
  }

  /// Mean Rec. 709 luma of an encoded image, 0..1.
  static Future<double?> lumaOf(Uint8List encoded) async {
    final codec = await ui.instantiateImageCodec(encoded, targetWidth: 32);
    final frame = await codec.getNextFrame();
    codec.dispose();
    final image = frame.image;
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    final n = image.width * image.height;
    image.dispose();
    if (data == null || n == 0) return null;
    var sum = 0.0;
    for (var i = 0; i < n * 4; i += 4) {
      sum +=
          0.2126 * data.getUint8(i) +
          0.7152 * data.getUint8(i + 1) +
          0.0722 * data.getUint8(i + 2);
    }
    return sum / (n * 255);
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    brightness.dispose();
  }
}
