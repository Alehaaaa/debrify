import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// Frosted white glass capsule for the player's gesture HUDs — the sidebar
/// pill's shape (full capsule, hairline rim, soft drop shadow) drawn as
/// blurred glass over the video.
class FrostedHudCapsule extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const FrostedHudCapsule({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
  });

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(999);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        // Soft, wide and low-contrast: an ambient lift plus a faint contact
        // shadow, never a hard edge under the glass.
        boxShadow: const [
          BoxShadow(
            color: Color(0x1F000000),
            blurRadius: 40,
            spreadRadius: -4,
            offset: Offset(0, 14),
          ),
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              borderRadius: radius,
              // A white sheen over a little dark tint keeps the white
              // content legible on bright frames too.
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: 0.22),
                  Colors.white.withValues(alpha: 0.12),
                ],
              ),
              color: Colors.black.withValues(alpha: 0.18),
              border: Border.all(color: Colors.white.withValues(alpha: 0.28)),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
