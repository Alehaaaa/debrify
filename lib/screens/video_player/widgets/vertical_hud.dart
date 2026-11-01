import 'package:flutter/material.dart';
import '../models/hud_state.dart';
import 'frosted_hud.dart';
import 'hud_level_icon.dart';

class VerticalHud extends StatelessWidget {
  final VerticalHudState hud;
  const VerticalHud({super.key, required this.hud});
  @override
  Widget build(BuildContext context) {
    final value = hud.value.clamp(0.0, 1.0);
    final label = (value * 100).round();
    return FrostedHudCapsule(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          HudLevelIcon(kind: hud.kind, value: value, size: 24),
          const SizedBox(height: 12),
          // A vertical meter that fills bottom-to-top along its length.
          SizedBox(
            key: const ValueKey('vertical-hud-meter'),
            height: 120,
            width: 6,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ColoredBox(color: Colors.white.withValues(alpha: 0.24)),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: FractionallySizedBox(
                      key: const ValueKey('vertical-hud-fill'),
                      widthFactor: 1,
                      heightFactor: value,
                      child: const ColoredBox(color: Colors.white),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: 34,
            child: Text(
              '$label',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
