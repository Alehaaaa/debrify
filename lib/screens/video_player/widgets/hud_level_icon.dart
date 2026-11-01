import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/hud_state.dart';

/// Volume / brightness glyph that follows the level continuously: the
/// speaker's waves fill in one by one (a cross at mute), the sun's core and
/// rays grow with brightness.
class HudLevelIcon extends StatelessWidget {
  final VerticalKind kind;
  final double value;
  final double size;
  final Color color;
  const HudLevelIcon({
    super.key,
    required this.kind,
    required this.value,
    this.size = 24,
    this.color = Colors.white,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    label: kind == VerticalKind.volume ? 'Volume' : 'Brightness',
    child: SizedBox.square(
      dimension: size,
      child: CustomPaint(
        painter: kind == VerticalKind.volume
            ? _VolumePainter(value.clamp(0.0, 1.0), color)
            : _SunPainter(value.clamp(0.0, 1.0), color),
      ),
    ),
  );
}

class _VolumePainter extends CustomPainter {
  final double v;
  final Color color;
  const _VolumePainter(this.v, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    Offset at(double x, double y) => Offset(x * s, y * s);
    final fill = Paint()..color = color;
    // Speaker: box + cone.
    canvas.drawPath(
      Path()
        ..moveTo(at(.12, .38).dx, at(.12, .38).dy)
        ..lineTo(at(.30, .38).dx, at(.30, .38).dy)
        ..lineTo(at(.50, .20).dx, at(.50, .20).dy)
        ..lineTo(at(.50, .80).dx, at(.50, .80).dy)
        ..lineTo(at(.30, .62).dx, at(.30, .62).dy)
        ..lineTo(at(.12, .62).dx, at(.12, .62).dy)
        ..close(),
      fill,
    );
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = s * .075;
    if (v <= 0.001) {
      stroke.color = color;
      canvas.drawLine(at(.62, .38), at(.86, .62), stroke);
      canvas.drawLine(at(.86, .38), at(.62, .62), stroke);
      return;
    }
    // Three waves, each fading in across its third of the range.
    for (var i = 0; i < 3; i++) {
      final t = ((v - i / 3) * 3).clamp(0.0, 1.0);
      final r = s * (.16 + i * .14);
      stroke.color = color.withValues(alpha: .22 + .78 * t);
      canvas.drawArc(
        Rect.fromCircle(center: at(.5, .5), radius: r),
        -math.pi / 4,
        math.pi / 2,
        false,
        stroke,
      );
    }
  }

  @override
  bool shouldRepaint(_VolumePainter old) => old.v != v || old.color != color;
}

class _SunPainter extends CustomPainter {
  final double v;
  final Color color;
  const _SunPainter(this.v, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final c = Offset(size.width / 2, size.height / 2);
    final core = s * (.15 + .07 * v);
    final paint = Paint()..color = color;
    if (v < .5) {
      // Dim: an outlined core, filling from the bottom as it brightens.
      canvas.drawCircle(
        c,
        core,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = s * .07,
      );
      canvas.save();
      canvas.clipRect(
        Rect.fromLTRB(0, c.dy + core - 2 * core * (v / .5), s, s),
      );
      canvas.drawCircle(c, core, paint);
      canvas.restore();
    } else {
      canvas.drawCircle(c, core, paint);
    }
    // Eight rays that lengthen with brightness.
    final rayPaint = Paint()
      ..color = color.withValues(alpha: .45 + .55 * v)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = s * .075;
    final inner = core + s * .09;
    final outer = inner + s * (.04 + .12 * v);
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      final d = Offset(math.cos(a), math.sin(a));
      canvas.drawLine(c + d * inner, c + d * outer, rayPaint);
    }
  }

  @override
  bool shouldRepaint(_SunPainter old) => old.v != v || old.color != color;
}
