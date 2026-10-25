import 'dart:math';

import 'package:flutter/material.dart';

import 'launch_ident.dart';

/// An original editorial logo reveal built from folding geometric panels.
///
/// The motion is intentionally shape-driven: four cards arrive from outside
/// the frame, hinge into a compact play mark, then hand the eye to the Nextup
/// wordmark. It borrows the broad cadence of premium identity motion without
/// reproducing any third-party logo, artwork, or animation frames.
class FoldIdent extends LaunchIdent {
  const FoldIdent();

  @override
  String get id => 'fold';

  @override
  String get label => 'Fold';

  @override
  String get subtitle =>
      'Geometric panels fold into the Nextup mark, then reveal the wordmark';

  @override
  Duration get revealDuration => const Duration(milliseconds: 1800);

  @override
  Color get baseColor => const Color(0xfff7f9fc);

  @override
  BoxDecoration get backdrop => const BoxDecoration(
    gradient: RadialGradient(
      center: Alignment(0, -0.12),
      radius: 1.15,
      colors: [Color(0xffffffff), Color(0xffeef3f9)],
    ),
  );

  @override
  Decoration themedBackdrop(IdentPalette p) => BoxDecoration(
    gradient: RadialGradient(
      center: const Alignment(0, -0.12),
      radius: 1.15,
      colors: [Color.lerp(p.base, p.ink, 0.08)!, p.base],
    ),
  );

  @override
  List<Color> get sweepColors => const [kNextupCyan, kNextupBlue, kNextupNavy];

  @override
  CustomPainter createPainter(
    Animation<double> animation, {
    required bool Function() isTelevision,
    IdentPalette? palette,
  }) => FoldPainter(animation, palette: palette);
}

class FoldPainter extends CustomPainter {
  FoldPainter(this.animation, {this.palette}) : super(repaint: animation);

  final Animation<double> animation;
  final IdentPalette? palette;

  static double _ease(double value) =>
      Curves.easeOutCubic.transform(identClamp(value, 0, 1));

  @override
  void paint(Canvas canvas, Size size) {
    final progress = animation.value;
    final shortest = min(size.width, size.height);
    final markSize = min(shortest * 0.25, size.width * 0.18);
    final center = Offset(size.width / 2, size.height * 0.46);
    final accent = palette?.accent ?? kNextupCyan;
    final ink = palette?.ink ?? kNextupNavy;

    final settle = Curves.easeOutBack.transform(
      identClamp((progress - 0.34) / 0.34, 0, 1),
    );
    final markScale = 0.84 + settle * 0.16;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(markScale, markScale);

    final panelPaint = Paint()..style = PaintingStyle.fill;
    final panels = <({Offset start, double turn, Color color})>[
      (
        start: Offset(-size.width * 0.56, -size.height * 0.38),
        turn: -0.72,
        color: accent,
      ),
      (
        start: Offset(size.width * 0.54, -size.height * 0.30),
        turn: 0.64,
        color: kNextupBlue,
      ),
      (
        start: Offset(-size.width * 0.48, size.height * 0.38),
        turn: 0.52,
        color: Color.lerp(kNextupCyan, Colors.white, 0.12)!,
      ),
      (
        start: Offset(size.width * 0.48, size.height * 0.36),
        turn: -0.58,
        color: Color.lerp(kNextupBlue, kNextupNavy, 0.28)!,
      ),
    ];

    for (var index = 0; index < panels.length; index++) {
      final local = _ease((progress - index * 0.035) / 0.5);
      final panel = panels[index];
      final offset = Offset.lerp(panel.start, Offset.zero, local)!;
      final angle = panel.turn * (1 - local);
      canvas.save();
      canvas.translate(offset.dx, offset.dy);
      canvas.rotate(angle);
      panelPaint.color = panel.color;
      final quadrant = Path();
      switch (index) {
        case 0:
          quadrant.moveTo(-markSize * 0.44, -markSize * 0.48);
          quadrant.lineTo(markSize * 0.08, -markSize * 0.18);
          quadrant.lineTo(-markSize * 0.12, 0);
          quadrant.lineTo(-markSize * 0.44, 0);
        case 1:
          quadrant.moveTo(markSize * 0.08, -markSize * 0.18);
          quadrant.lineTo(markSize * 0.44, 0);
          quadrant.lineTo(markSize * 0.10, markSize * 0.10);
          quadrant.lineTo(-markSize * 0.12, 0);
        case 2:
          quadrant.moveTo(-markSize * 0.44, 0);
          quadrant.lineTo(-markSize * 0.12, 0);
          quadrant.lineTo(markSize * 0.10, markSize * 0.10);
          quadrant.lineTo(-markSize * 0.44, markSize * 0.48);
        case 3:
          quadrant.moveTo(markSize * 0.10, markSize * 0.10);
          quadrant.lineTo(markSize * 0.44, 0);
          quadrant.lineTo(markSize * 0.44, markSize * 0.30);
          quadrant.lineTo(markSize * 0.08, markSize * 0.48);
      }
      quadrant.close();
      canvas.drawPath(quadrant, panelPaint);
      canvas.restore();
    }
    canvas.restore();

    final wordProgress = _ease((progress - 0.58) / 0.30);
    if (wordProgress <= 0) return;
    final word = TextPainter(
      text: TextSpan(
        text: kIdentWord,
        style: TextStyle(
          color: ink.withValues(alpha: wordProgress),
          fontSize: markSize * 0.31,
          fontFamily: kNextupDisplayFont,
          fontWeight: FontWeight.w800,
          letterSpacing: -markSize * 0.006,
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final wordY = center.dy + markSize * 0.66;
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(
        center.dx - word.width / 2,
        wordY,
        word.width * wordProgress,
        word.height,
      ),
    );
    word.paint(canvas, Offset(center.dx - word.width / 2, wordY));
    canvas.restore();

    final rulePaint = Paint()
      ..color = accent.withValues(alpha: wordProgress * 0.72)
      ..strokeWidth = max(1.5, markSize * 0.012)
      ..strokeCap = StrokeCap.round;
    final ruleWidth = word.width * 0.64 * wordProgress;
    canvas.drawLine(
      Offset(center.dx - ruleWidth / 2, wordY + word.height + markSize * 0.10),
      Offset(center.dx + ruleWidth / 2, wordY + word.height + markSize * 0.10),
      rulePaint,
    );
  }

  @override
  bool shouldRepaint(covariant FoldPainter oldDelegate) =>
      oldDelegate.animation != animation || oldDelegate.palette != palette;
}
