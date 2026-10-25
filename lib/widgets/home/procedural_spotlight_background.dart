import 'dart:math' as math;

import 'package:flutter/material.dart';

enum SpotlightAtmosphere { northernLights, emberDusk, meteorNight }

/// Lightweight, resolution-independent Spotlight scenes.
///
/// Static gradients live outside the painter; the painter only redraws the
/// moving ribbons or particles. [AnimationController] automatically follows
/// TickerMode, so hidden Spotlight routes do not consume animation frames.
class ProceduralSpotlightBackground extends StatefulWidget {
  const ProceduralSpotlightBackground({
    super.key,
    required this.atmosphere,
    this.lowPower = false,
  });

  final SpotlightAtmosphere atmosphere;
  final bool lowPower;

  @override
  State<ProceduralSpotlightBackground> createState() =>
      _ProceduralSpotlightBackgroundState();
}

class _ProceduralSpotlightBackgroundState
    extends State<ProceduralSpotlightBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _clock = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 40),
  )..repeat();

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = switch (widget.atmosphere) {
      SpotlightAtmosphere.northernLights => const [
        Color(0xff06101d),
        Color(0xff0a1a2a),
        Color(0xff031019),
      ],
      SpotlightAtmosphere.emberDusk => const [
        Color(0xff210d13),
        Color(0xff351716),
        Color(0xff0c090d),
      ],
      SpotlightAtmosphere.meteorNight => const [
        Color(0xff050817),
        Color(0xff101735),
        Color(0xff03050c),
      ],
    };
    return IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: colors,
              ),
            ),
            child: CustomPaint(
              painter: _AtmospherePainter(
                _clock,
                widget.atmosphere,
                widget.lowPower,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _AtmospherePainter extends CustomPainter {
  _AtmospherePainter(this.clock, this.atmosphere, this.lowPower)
    : super(repaint: clock);

  final Animation<double> clock;
  final SpotlightAtmosphere atmosphere;
  final bool lowPower;
  final Paint _paint = Paint();

  static final _stars = List.generate(150, (index) {
    final random = math.Random(index * 83 + 11);
    return (
      x: random.nextDouble(),
      y: random.nextDouble() * 0.78,
      size: 0.35 + random.nextDouble() * 1.35,
      phase: random.nextDouble() * math.pi * 2,
    );
  });

  static final _embers = List.generate(90, (index) {
    final random = math.Random(index * 61 + 29);
    return (
      x: random.nextDouble(),
      y: random.nextDouble(),
      speed: 0.08 + random.nextDouble() * 0.19,
      sway: 8.0 + random.nextDouble() * 24,
      size: 0.7 + random.nextDouble() * 2.1,
      phase: random.nextDouble() * math.pi * 2,
    );
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final time = clock.value * 40;
    switch (atmosphere) {
      case SpotlightAtmosphere.northernLights:
        _paintAurora(canvas, size, time);
      case SpotlightAtmosphere.emberDusk:
        _paintEmbers(canvas, size, time);
      case SpotlightAtmosphere.meteorNight:
        _paintMeteors(canvas, size, time);
    }
  }

  void _paintAurora(Canvas canvas, Size size, double time) {
    final count = lowPower ? 3 : 5;
    for (var band = 0; band < count; band++) {
      final path = Path();
      final baseY = size.height * (0.10 + band * 0.075);
      path.moveTo(-40, baseY);
      for (var step = 0; step <= 12; step++) {
        final x = size.width * step / 12;
        final wave = math.sin(step * 0.72 + time * 0.22 + band * 1.3);
        path.lineTo(x, baseY + wave * size.height * (0.035 + band * 0.006));
      }
      path.lineTo(size.width + 40, baseY + size.height * 0.24);
      path.lineTo(-40, baseY + size.height * 0.19);
      path.close();
      final color = band.isEven
          ? const Color(0xff56efc1)
          : const Color(0xff7798ff);
      _paint.shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: 0.18),
          color.withValues(alpha: 0.035),
          Colors.transparent,
        ],
      ).createShader(Offset.zero & size);
      canvas.drawPath(path, _paint);
    }
    _paint.shader = null;
  }

  void _paintEmbers(Canvas canvas, Size size, double time) {
    final count = lowPower ? 48 : _embers.length;
    for (final ember in _embers.take(count)) {
      final travel = (ember.y - time * ember.speed) % 1.15;
      final y = size.height * (1.08 - travel);
      final x =
          ember.x * size.width +
          math.sin(time * 0.8 + ember.phase) * ember.sway;
      final life = math.sin(travel.clamp(0, 1) * math.pi).clamp(0.0, 1.0);
      _paint
        ..shader = null
        ..color = Color.lerp(
          const Color(0xffff8b3d),
          const Color(0xffffd27d),
          ember.size / 3,
        )!.withValues(alpha: life * 0.72);
      canvas.drawCircle(Offset(x, y), ember.size, _paint);
    }
    _paint.shader = const RadialGradient(
      center: Alignment(0, 1.15),
      radius: 0.9,
      colors: [Color(0x42ff6535), Color(0x00ff6535)],
    ).createShader(Offset.zero & size);
    canvas.drawRect(Offset.zero & size, _paint);
    _paint.shader = null;
  }

  void _paintMeteors(Canvas canvas, Size size, double time) {
    final starCount = lowPower ? 80 : _stars.length;
    for (final star in _stars.take(starCount)) {
      final twinkle = 0.28 + (math.sin(time * 0.9 + star.phase) + 1) * 0.18;
      _paint
        ..shader = null
        ..color = const Color(0xffdbe9ff).withValues(alpha: twinkle);
      canvas.drawCircle(
        Offset(star.x * size.width, star.y * size.height),
        star.size,
        _paint,
      );
    }
    final meteorCount = lowPower ? 2 : 4;
    for (var index = 0; index < meteorCount; index++) {
      final phase = (time * (0.075 + index * 0.009) + index * 0.27) % 1.0;
      final x = size.width * (1.12 - phase * 1.45);
      final y = size.height * (-0.08 + phase * 0.82 + index * 0.045);
      final length = size.shortestSide * (0.12 + index * 0.018);
      _paint
        ..shader = LinearGradient(
          colors: [
            Colors.transparent,
            const Color(0xff9fc6ff).withValues(alpha: 0.18),
            const Color(0xffffffff).withValues(alpha: 0.88),
          ],
        ).createShader(Rect.fromLTWH(x, y - length, length, length))
        ..strokeWidth = 1.2 + index * 0.25
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(x + length * 0.72, y - length * 0.72),
        Offset(x, y),
        _paint,
      );
    }
    _paint.shader = null;
  }

  @override
  bool shouldRepaint(covariant _AtmospherePainter oldDelegate) =>
      oldDelegate.clock != clock ||
      oldDelegate.atmosphere != atmosphere ||
      oldDelegate.lowPower != lowPower;
}
