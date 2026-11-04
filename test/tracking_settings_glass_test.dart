import 'package:debrify/models/tracking_source.dart';
import 'package:debrify/screens/settings/tracking_settings_page.dart';
import 'package:debrify/services/profiles/profile_runtime.dart';
import 'package:debrify/services/secret_vault.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/theme/glass_chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final appearance in ['glass', 'legacy']) {
    testWidgets('Tracking nested progress popup reopens in $appearance', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      SecretVault.debugReset(deviceIdOverride: 'tracking-glass-test');
      ProfileRuntime.debugReset();
      ProfileRuntime.initializeLegacy();
      addTearDown(ProfileRuntime.debugReset);
      await tester.binding.setSurfaceSize(const Size(900, 750));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final app = AppThemes.byId(appearance);
      await tester.pumpWidget(
        AppThemeScope(
          theme: app,
          child: const MaterialApp(home: TrackingSettingsPage()),
        ),
      );
      await tester.pumpAndSettle();
      final progress = find.byType(
        DropdownButtonFormField<WatchProgressSource>,
      );
      expect(progress, findsOneWidget);
      final field = tester.widget<InputDecorator>(
        find.descendant(of: progress, matching: find.byType(InputDecorator)),
      );
      expect(
        field.decoration.fillColor,
        appearance == 'glass' ? GlassChrome.field(app) : null,
      );

      await tester.tap(progress);
      await tester.pumpAndSettle();
      await tester.tap(find.text('This device').last);
      await tester.pumpAndSettle();
      await tester.tap(progress);
      await tester.pumpAndSettle();
      expect(find.text('Smart').last, findsOneWidget);
      await tester.tap(find.text('Smart').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
