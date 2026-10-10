import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:debrify/services/text_brightness.dart';
import 'package:debrify/theme/app_theme_adapter.dart';
import 'package:debrify/theme/glass_chrome.dart';
import 'package:debrify/theme/premium_looks.dart';

void main() {
  setUp(() => AppThemeAdapter.debugUseTestTypography = true);
  tearDown(() => AppThemeAdapter.debugUseTestTypography = false);

  test(
    'Glass surfaces share the material palette across Material controls',
    () {
      final app = PremiumLooks.glass.build();
      final theme = AppThemeAdapter.themed(app, TextBrightness.bright);

      expect(GlassChrome.enabled(app), isTrue);
      expect(theme.cardTheme.color, GlassChrome.fill(app));
      expect(
        theme.dialogTheme.backgroundColor,
        GlassChrome.fill(app, raised: true),
      );
      expect(theme.popupMenuTheme.color, GlassChrome.fill(app, raised: true));
      expect(
        theme.bottomSheetTheme.backgroundColor,
        GlassChrome.fill(app, raised: true),
      );
      expect(theme.inputDecorationTheme.fillColor, GlassChrome.field(app));
      expect(theme.chipTheme.backgroundColor, GlassChrome.fill(app));
      expect(theme.cardTheme.shape, isA<RoundedRectangleBorder>());
    },
  );

  test('Other looks retain their own opaque Material surfaces', () {
    final app = PremiumLooks.field.build();
    final theme = AppThemeAdapter.themed(app, TextBrightness.bright);

    expect(GlassChrome.enabled(app), isFalse);
    expect(theme.bottomSheetTheme.backgroundColor, isNull);
    expect(theme.cardTheme.color?.a, 1);
    expect(theme.dialogTheme.backgroundColor?.a, 1);
  });
}
