import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../../theme/app_theme_scope.dart';

/// Loads one Impeller runtime effect per app process, not one per moving
/// control. The engine owns the backdrop sampler and size floats. No screenshot
/// is captured: the filter sees whatever Flutter has actually composited
/// behind the glass on each rasterized frame. Platform video overlays that
/// bypass Flutter composition cannot be promised as filter input.
class _GlassRefractionProgram {
  static const asset = 'assets/shaders/player_liquid_glass.frag';
  static final ValueNotifier<ui.FragmentProgram?> ready = ValueNotifier(null);
  static bool _started = false;
  static bool _failed = false;

  static void warm() {
    if (_started || !ui.ImageFilter.isShaderFilterSupported) return;
    _started = true;
    unawaited(_load());
  }

  static Future<void> _load() async {
    try {
      ready.value = await ui.FragmentProgram.fromAsset(asset);
    } catch (error) {
      _failed = true;
      debugPrint(
        'GlassSurface: Impeller shader failed ($error); '
        'using Skia-compatible blur and subtle chromatic rim',
      );
    }
  }

  static ui.ImageFilter? filter({
    required double physicalRadius,
    required double physicalRefraction,
    required double physicalDispersion,
    required double saturation,
    required double phase,
    required Offset physicalOrigin,
    required Size physicalSize,
  }) {
    final program = ready.value;
    if (_failed || !ui.ImageFilter.isShaderFilterSupported || program == null) {
      return null;
    }
    try {
      final shader = program.fragmentShader();
      // 0,1 = u_size, set by Flutter's image-filter backend.
      // sampler 0 = live input, also bound by Flutter. Never set these.
      shader.setFloat(2, physicalRadius);
      shader.setFloat(3, physicalRefraction);
      shader.setFloat(4, physicalDispersion);
      shader.setFloat(5, saturation);
      // A bounded angle, updated at 10 Hz only while primary player glass is
      // mounted and motion is enabled. Each instance has its OWN filter, not
      // a shared screen-wide distortion clipped into button-shaped masks.
      shader.setFloat(6, phase);
      // Filter input may contain a larger window-aligned snapshot even though
      // this control owns a small clip. Locate the lens using this control's
      // *own* paint bounds; never assume u_size is the control itself.
      shader.setFloat(7, physicalOrigin.dx);
      shader.setFloat(8, physicalOrigin.dy);
      shader.setFloat(9, physicalSize.width);
      shader.setFloat(10, physicalSize.height);
      return ui.ImageFilter.shader(shader);
    } on UnsupportedError catch (error) {
      _failed = true;
      debugPrint('GlassSurface: shader backend unavailable ($error)');
      return null;
    } on StateError catch (error) {
      _failed = true;
      debugPrint('GlassSurface: invalid shader input ($error)');
      return null;
    }
  }

  static String get diagnostic {
    if (!ui.ImageFilter.isShaderFilterSupported) {
      return 'Skia/non-Impeller fallback: Gaussian frost and painted chromatic rim';
    }
    if (_failed) return 'Impeller shader load failed: fallback blur/rim';
    if (ready.value == null) {
      return 'Impeller shader loading: fallback blur/rim';
    }
    return 'Impeller refracted live Flutter backdrop (video texture unverified)';
  }
}

/// One lightweight motion clock for the entire player. The moving video is
/// sampled by the compositor on every rendered frame regardless of this clock;
/// this clock only makes the *shape* of the edge lens flex subtly. Never read
/// pixels from the video, never tick on Skia, and stop when the last primary
/// surface leaves the tree or the application is backgrounded.
class _GlassMotionClock extends ValueNotifier<double>
    with WidgetsBindingObserver {
  _GlassMotionClock() : super(0);

  static final instance = _GlassMotionClock();
  static const cadence = Duration(milliseconds: 100); // at most 10 updates/s
  int _subscribers = 0;
  int _step = 0;
  Timer? _timer;
  bool _foreground = true;

  @override
  void addListener(VoidCallback listener) {
    super.addListener(listener);
    if (_subscribers++ == 0) {
      WidgetsBinding.instance.addObserver(this);
      _updateTimer();
    }
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (_subscribers > 0 && --_subscribers == 0) {
      _timer?.cancel();
      _timer = null;
      WidgetsBinding.instance.removeObserver(this);
      _step = 0;
      value = 0;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateTimer();
  }

  void _updateTimer() {
    _timer?.cancel();
    _timer = null;
    if (_subscribers == 0 || !_foreground) return;
    _timer = Timer.periodic(cadence, (_) {
      // 8-second loop; bounded shader angles avoid precision drift during
      // long-running playback and never allocate a backdrop capture.
      _step = (_step + 1) % 80;
      value = _step * (2 * math.pi / 80);
    });
  }

  @visibleForTesting
  int get activeConsumers => _subscribers;
}

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
/// On Impeller, the loaded fragment shader actually refracts the composited
/// moving backdrop, splitting red/blue only at the glass boundary. On Skia,
/// inaccessible contrast or unrelated Legacy surfaces, the safe fallback
/// retains Gaussian frost and a restrained painted rim. The player always
/// has a frozen Legacy boundary, so only its glass controls opt in to lensing
/// without changing the route's original theme/other TV chrome.
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

  /// Optical tuning in logical pixels; shader uniforms use physical pixels.
  final double refractionPx;
  final double strongRefractionPx;
  final double dispersionPx;
  final double strongDispersionPx;
  final double shaderBlurFraction;
  final double shaderMaxBlur;
  final double fallbackMaxBlur;

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
    required this.refractionPx,
    required this.strongRefractionPx,
    required this.dispersionPx,
    required this.strongDispersionPx,
    required this.shaderBlurFraction,
    required this.shaderMaxBlur,
    required this.fallbackMaxBlur,
  });

  static const String asset = 'assets/design/glass_tokens.json';

  static const GlassTokens defaults = GlassTokens(
    radiusPanel: 24,
    radiusPanelCompact: 20,
    radiusSheet: 26,
    rimWidth: 1.3,
    rimHighlight: Color(0xC2FFFFFF),
    rimMid: Color(0x12FFFFFF),
    rimLowlight: Color(0x33FFFFFF),
    sheen: Color(0x14FFFFFF),
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
    refractionPx: 14.0,
    strongRefractionPx: 18.0,
    dispersionPx: 4.0,
    strongDispersionPx: 5.0,
    shaderBlurFraction: 0.14,
    shaderMaxBlur: 3.0,
    fallbackMaxBlur: 16.0,
  );

  factory GlassTokens.fromJson(Map<String, dynamic> j) {
    final radius = j['radius'] as Map<String, dynamic>;
    final rim = j['rim'] as Map<String, dynamic>;
    final shadow = j['shadow'] as Map<String, dynamic>;
    final variants = j['variants'] as Map<String, dynamic>;
    final dyn = variants['dynamic'] as Map<String, dynamic>;
    final dynCfg = j['dynamic'] as Map<String, dynamic>;
    final reduced = j['reducedTransparency'] as Map<String, dynamic>;
    final optics = j['optics'] as Map<String, dynamic>;
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
      refractionPx: (optics['refractionPx'] as num).toDouble(),
      strongRefractionPx: (optics['strongRefractionPx'] as num).toDouble(),
      dispersionPx: (optics['dispersionPx'] as num).toDouble(),
      strongDispersionPx: (optics['strongDispersionPx'] as num).toDouble(),
      shaderBlurFraction: (optics['shaderBlurFraction'] as num).toDouble(),
      shaderMaxBlur: (optics['shaderMaxBlur'] as num).toDouble(),
      fallbackMaxBlur: (optics['fallbackMaxBlur'] as num).toDouble(),
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
    refractionPx,
    strongRefractionPx,
    dispersionPx,
    strongDispersionPx,
    shaderBlurFraction,
    shaderMaxBlur,
    fallbackMaxBlur,
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

/// Tracks where ONE glass pane is composited. ImageFilter.shader receives a
/// renderer-owned u_size, which on Impeller may include a whole-screen-sized
/// backdrop texture; centering a lens on that texture makes small buttons
/// mere masks over a single screen-centered distortion. This measurement is
/// fed to each independent shader in *physical pixels* after layout.
///
/// Measurement is post-frame (never setState during layout/build), creates no
/// GlobalKeys/overlays and updates only if the actual geometry changes.
class _LocalGlassGeometry extends StatefulWidget {
  const _LocalGlassGeometry({required this.builder});

  final Widget Function(BuildContext context, Rect? bounds) builder;

  @override
  State<_LocalGlassGeometry> createState() => _LocalGlassGeometryState();
}

class _LocalGlassGeometryState extends State<_LocalGlassGeometry> {
  Rect? _bounds;
  bool _measureQueued = false;

  void _measureLater() {
    if (_measureQueued) return;
    _measureQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measureQueued = false;
      if (!mounted) return;
      final render = context.findRenderObject();
      if (render is! RenderBox || !render.hasSize) return;
      final next = render.localToGlobal(Offset.zero) & render.size;
      if (!next.isFinite || next.width <= 0 || next.height <= 0) return;
      final prev = _bounds;
      if (prev != null &&
          (next.left - prev.left).abs() < 0.5 &&
          (next.top - prev.top).abs() < 0.5 &&
          (next.width - prev.width).abs() < 0.5 &&
          (next.height - prev.height).abs() < 0.5) {
        return;
      }
      setState(() => _bounds = next);
    });
  }

  @override
  Widget build(BuildContext context) {
    _measureLater();
    return widget.builder(context, _bounds);
  }
}

/// A piece of liquid glass.
class GlassSurface extends StatelessWidget {
  /// The refraction shader is shared with the whole player and registered
  /// under flutter.shaders. Existing callers need no integration changes.
  static const String liquidShaderAsset = _GlassRefractionProgram.asset;

  /// Renderer diagnostic, never an assertion that native video textures were
  /// included in Flutter's composited backdrop.
  @visibleForTesting
  static String get shaderBackendDiagnostic =>
      _GlassRefractionProgram.diagnostic;

  @visibleForTesting
  static bool canRefractBackdrop({
    required bool impeller,
    required bool shaderReady,
    required bool highContrast,
    required bool legacy,
    bool playerChrome = false,
  }) => impeller && shaderReady && !highContrast && (!legacy || playerChrome);

  /// Motion belongs to primary, player-only chrome. Secondary controls keep
  /// static lens geometry and still refract the *moving* composited backdrop.
  @visibleForTesting
  static bool shouldAnimateLens({
    required bool impeller,
    required bool shaderReady,
    required bool highContrast,
    required bool reduceMotion,
    required bool legacy,
    required bool playerChrome,
    required bool primary,
  }) =>
      primary &&
      !reduceMotion &&
      playerChrome &&
      canRefractBackdrop(
        impeller: impeller,
        shaderReady: shaderReady,
        highContrast: highContrast,
        legacy: legacy,
        playerChrome: playerChrome,
      );

  @visibleForTesting
  static int get activeMotionConsumers =>
      _GlassMotionClock.instance.activeConsumers;

  final Widget child;
  final BorderRadius radius;
  final EdgeInsetsGeometry padding;
  final GlassVariant variant;

  /// A brighter sheen — for the primary play button.
  final bool strong;

  /// Scales the drop shadow: 1 for panels, less for small buttons, whose
  /// shadow would otherwise sit far below them.
  final double shadowScale;

  /// Player routes are intentionally FrozenLegacyPageRoute even when a live
  /// theme was selected. Opt in just this player chrome, never its siblings.
  final bool allowLegacyRefraction;

  /// Skips the specular rim stroke. The rim reads as a soft light-catch on a
  /// small circle but as a hard continuous outline ("border") on a large
  /// straight-edged rectangle, so wide panels opt out and rely on frost + tint
  /// for their edge, matching the borderless look of the floating buttons.
  final bool borderless;

  const GlassSurface({
    super.key,
    required this.child,
    required this.radius,
    this.padding = EdgeInsets.zero,
    this.variant = GlassVariant.frosted,
    this.strong = false,
    this.shadowScale = 1,
    this.allowLegacyRefraction = false,
    this.borderless = false,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = GlassTokens.current;
    final reduced = MediaQuery.maybeHighContrastOf(context) ?? false;
    final app = AppThemeScope.of(context);
    if (!reduced && (!app.isLegacy || allowLegacyRefraction)) {
      _GlassRefractionProgram.warm();
    }
    // The program arrives asynchronously. One notification rebuilds the glass
    // to switch from safe blur to shader; subsequent moving video frames are
    // sampled by the engine, not by a Dart animation or screenshot loop.
    return _LocalGlassGeometry(
      builder: (context, lensBounds) =>
          ValueListenableBuilder<ui.FragmentProgram?>(
            valueListenable: _GlassRefractionProgram.ready,
            builder: (context, program, child) {
              final motion = shouldAnimateLens(
                impeller: ui.ImageFilter.isShaderFilterSupported,
                shaderReady: program != null,
                highContrast: reduced,
                reduceMotion:
                    MediaQuery.maybeOf(context)?.disableAnimations ?? false,
                legacy: app.isLegacy,
                playerChrome: allowLegacyRefraction,
                primary: strong || variant == GlassVariant.dynamic,
              );
              if (!motion) {
                return _buildResolved(context, tokens, 0, lensBounds);
              }
              return ValueListenableBuilder<double>(
                valueListenable: _GlassMotionClock.instance,
                builder: (context, phase, child) =>
                    _buildResolved(context, tokens, phase, lensBounds),
              );
            },
          ),
    );
  }

  Widget _buildResolved(
    BuildContext context,
    GlassTokens tokens,
    double phase,
    Rect? lensBounds,
  ) {
    if (variant != GlassVariant.dynamic) {
      return _paint(
        context,
        tokens,
        tokens.look(variant, 0),
        phase,
        lensBounds,
      );
    }
    final brightness =
        GlassBrightnessScope.of(context) ?? tokens.defaultBrightness;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: brightness),
      duration: (MediaQuery.maybeOf(context)?.disableAnimations ?? false)
          ? Duration.zero
          : tokens.transition,
      curve: Curves.easeOut,
      builder: (context, b, _) =>
          _paint(context, tokens, tokens.look(variant, b), phase, lensBounds),
    );
  }

  Widget _paint(
    BuildContext context,
    GlassTokens t,
    GlassLook look,
    double phase,
    Rect? lensBounds,
  ) {
    // "Reduce transparency" / high contrast: a solid, legible plate, no blur.
    final reduced = MediaQuery.maybeHighContrastOf(context) ?? false;
    final legacy = AppThemeScope.of(context).isLegacy;
    final physical = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
    final corners = radius.resolve(Directionality.of(context));
    final minRadius = [
      corners.topLeft.x,
      corners.topRight.x,
      corners.bottomRight.x,
      corners.bottomLeft.x,
    ].reduce((a, b) => a < b ? a : b);
    final shaderFilter =
        canRefractBackdrop(
          impeller: ui.ImageFilter.isShaderFilterSupported,
          shaderReady: _GlassRefractionProgram.ready.value != null,
          highContrast: reduced,
          legacy: legacy,
          playerChrome: allowLegacyRefraction,
        )
        ? _GlassRefractionProgram.filter(
            physicalRadius: minRadius * physical,
            physicalRefraction:
                (strong ? t.strongRefractionPx : t.refractionPx) * physical,
            physicalDispersion:
                (strong ? t.strongDispersionPx : t.dispersionPx) * physical,
            saturation: look.saturation,
            phase: phase,
            physicalOrigin: (lensBounds?.topLeft ?? Offset.zero) * physical,
            physicalSize: (lensBounds?.size ?? Size.zero) * physical,
          )
        : null;
    final refracting = shaderFilter != null;
    // Skia on macOS cannot run ImageFilter.shader. There is no honest way to
    // refract or split the backdrop per-channel on Skia, so the fallback keeps
    // the backdrop registered 1:1 and relies on frost + the specular rim; the
    // real lensing, edge blur ramp and radial dispersion are the Impeller
    // shader's job.
    final playerFallback = allowLegacyRefraction && !refracting && !reduced;
    final sheen = strong
        ? t.sheen.withValues(alpha: (t.sheen.a * 1.8).clamp(0.0, 1.0))
        : t.sheen;
    // A restrained neutral-gray veil: the backdrop's actual colors still pass
    // through instead of being buried under an opaque milky plate.
    final tint = (refracting || playerFallback)
        ? Color.lerp(look.tint, const Color(0x161B1D22), 0.62)!
        : look.tint;
    final shade = (refracting || playerFallback)
        ? Color.lerp(
            look.shade,
            const Color(0x1F171A20),
            variant == GlassVariant.translucent ? 0.48 : 0.76,
          )!
        : look.shade;
    final tintTop = Color.alphaBlend(sheen, tint);

    Widget body = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        color: reduced ? t.reducedTransparencyShade : shade,
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: radius,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [tintTop, tint, tint],
            stops: const [0.0, 0.5, 1.0],
          ),
        ),
        child: CustomPaint(
          foregroundPainter: borderless
              ? null
              : _RimPainter(radius: radius, tokens: t),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );

    if (!reduced && look.blur > 0) {
      final blur = refracting
          ? (look.blur * t.shaderBlurFraction)
                .clamp(1.5, t.shaderMaxBlur)
                .toDouble()
          : playerFallback
          ? (look.blur * 0.13).clamp(1.0, 2.8).toDouble()
          : (legacy
                ? look.blur
                : look.blur.clamp(4.0, t.fallbackMaxBlur).toDouble());
      final frost = ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur);
      // Skia cannot run the refraction shader, and an affine magnification only
      // slides the backdrop out of register, so the glass looks like an offset
      // copy of the video rather than a window onto it. The fallback therefore
      // samples the real backdrop 1:1 — frost + saturation — and sells the glass
      // with the specular rim, not a fake lens or a painted colour fringe.
      final filter = ui.ImageFilter.compose(
        outer: refracting
            ? shaderFilter
            : ColorFilter.matrix(_saturation(look.saturation)),
        inner: frost,
      );
      // Never use BackdropFilter.grouped here: its shared backdrop key makes
      // neighbouring controls sample one common effect instead of each local
      // curved pane. Every pane gets an independent image-filter layer and
      // clipped sampling bounds. The child's icon/text sits ABOVE the filter.
      body = BackdropFilter(filter: filter, child: body);
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
    // A neutral white specular edge only — no painted colour. A coloured fringe
    // reads as green/red edges over dark video (additive light doesn't cancel
    // to white over a dark backdrop); real chromatic dispersion is the Impeller
    // shader's job, sampled from the backdrop, never painted on Skia.
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
