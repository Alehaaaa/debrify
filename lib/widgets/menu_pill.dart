import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../theme/app_motion.dart';
import '../theme/app_theme.dart';
import '../theme/app_theme_scope.dart';
import '../theme/glass_chrome.dart';

/// The shared bottom-right navigation control for pointer and touch layouts.
class MenuPill extends StatelessWidget {
  final bool isOpen;
  final VoidCallback onTap;
  final double pulseValue;
  final Key? pillKey;

  const MenuPill({
    super.key,
    required this.isOpen,
    required this.onTap,
    this.pulseValue = 0,
    this.pillKey,
  });

  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    final frosted = app.formId == 'glass';
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: app.shape.br(22),
          boxShadow: const [
            BoxShadow(
              color: Color(0x66000000),
              blurRadius: 18,
              offset: Offset(0, 6),
              spreadRadius: -2,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: app.shape.br(22),
          child: BackdropFilter(
            // A navigation control is always frosted, regardless of a
            // screen theme that chooses a flat card separation model.
            filter: ImageFilter.blur(sigmaX: 22, sigmaY: 22),
            child: AnimatedContainer(
              key: pillKey,
              duration: AppMotion.of(
                context,
              ).scaled(const Duration(milliseconds: 250)),
              height: 44,
              padding: const EdgeInsets.symmetric(horizontal: 14),
              decoration: BoxDecoration(
                // Enough dark material to remain legible over a poster, with
                // the backdrop blur still visible rather than a solid chip.
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    app.shell.railBg.withValues(
                      alpha: frosted
                          ? (isOpen ? 0.65 : 0.56)
                          : (isOpen ? 0.84 : 0.78),
                    ),
                    (frosted ? app.core.pane : app.shell.ink).withValues(
                      alpha: frosted
                          ? (isOpen ? 0.58 : 0.48)
                          : (isOpen ? 0.74 : 0.68),
                    ),
                  ],
                ),
                borderRadius: app.shape.br(22),
                border: Border.all(
                  color: frosted
                      ? GlassChrome.edge(app, active: isOpen)
                      : app.fade(app.core.tx, isOpen ? 0.34 : 0.28),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _MenuPillIcon(
                    isOpen: isOpen,
                    pulseValue: pulseValue,
                    app: app,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    isOpen ? 'Close' : 'Menu',
                    style: TextStyle(
                      color: app.fade(app.core.tx, 0.92),
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.3,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuPillIcon extends StatelessWidget {
  final bool isOpen;
  final double pulseValue;
  final AppTheme app;

  const _MenuPillIcon({
    required this.isOpen,
    required this.pulseValue,
    required this.app,
  });

  @override
  Widget build(BuildContext context) {
    if (isOpen) return Icon(Icons.close_rounded, color: app.core.tx, size: 16);
    return SizedBox(
      width: 14,
      height: 14,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _MenuDot(opacity: 0.9 + 0.1 * pulseValue, app: app),
              _MenuDot(opacity: 0.7 + 0.3 * (1 - pulseValue), app: app),
            ],
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _MenuDot(opacity: 0.7 + 0.3 * (1 - pulseValue), app: app),
              _MenuDot(opacity: 0.9 + 0.1 * pulseValue, app: app),
            ],
          ),
        ],
      ),
    );
  }
}

class _MenuDot extends StatelessWidget {
  final double opacity;
  final AppTheme app;

  const _MenuDot({required this.opacity, required this.app});

  @override
  Widget build(BuildContext context) => Container(
    width: 4,
    height: 4,
    decoration: BoxDecoration(
      color: app.fade(app.core.tx, opacity),
      borderRadius: app.shape.br(1.25),
    ),
  );
}
