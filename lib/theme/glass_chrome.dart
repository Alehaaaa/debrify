import 'package:flutter/material.dart';

import 'app_surface.dart';
import 'app_theme.dart';

/// Shared palette for controls that sit *inside* a frosted page.
///
/// Large floating panes own the actual backdrop filter via GlassSurface. Cards,
/// rows, fields and Material popups reuse these translucent fills and lit
/// hairlines without each allocating another expensive blur layer.
abstract final class GlassChrome {
  static bool enabled(AppTheme theme) =>
      theme.surface.base == SeparationModel.glass;

  static Color fill(AppTheme theme, {bool raised = false}) => Color.alphaBlend(
    theme.core.tx.withValues(alpha: raised ? 0.095 : 0.055),
    theme.core.pane,
  ).withValues(alpha: raised ? 0.78 : 0.62);

  static Color edge(AppTheme theme, {bool active = false}) => Color.lerp(
    theme.core.tx,
    theme.core.accent,
    active ? 0.48 : 0.10,
  )!.withValues(alpha: active ? 0.48 : 0.25);

  static Color field(AppTheme theme) => theme.core.pane.withValues(alpha: 0.68);

  static RoundedRectangleBorder shape(
    AppTheme theme, {
    double radius = 16,
    bool active = false,
  }) => RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(radius),
    side: BorderSide(color: edge(theme, active: active)),
  );

  static BoxDecoration decoration(
    AppTheme theme, {
    BorderRadius? radius,
    bool raised = false,
    bool active = false,
  }) => BoxDecoration(
    color: fill(theme, raised: raised),
    borderRadius: radius ?? theme.shape.br(16),
    border: Border.all(color: edge(theme, active: active)),
  );
}
