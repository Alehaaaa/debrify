import 'dart:convert';
import 'package:debrify/screens/settings/stream_badges_settings_page.dart';
import 'package:debrify/services/stream_badges_service.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/theme/glass_chrome.dart';
import 'package:debrify/theme/premium_looks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('nested ruleset actions reopen with glass and persist toggles', (
    tester,
  ) async {
    final source = StreamBadgeSource(
      id: 'glass-source',
      name: 'Glass ruleset',
      json: jsonEncode({
        'filters': [
          {'name': 'HD', 'pattern': '1080p'},
        ],
      }),
    );
    SharedPreferences.setMockInitialValues({
      StreamBadgesService.sourcesKey: jsonEncode([source.toJson()]),
    });
    final svc = StreamBadgesService.instance;
    svc.resetProfileScope();
    addTearDown(svc.resetProfileScope);
    final app = PremiumLooks.glass.build();
    await tester.binding.setSurfaceSize(const Size(700, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: AppThemeScope(
          theme: app,
          child: const StreamBadgesSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    for (final action in ['Close', 'Disable']) {
      await tester.ensureVisible(find.text('Glass ruleset'));
      await tester.tap(find.text('Glass ruleset'));
      await tester.pumpAndSettle();
      final dialogTheme = Theme.of(
        tester.element(find.byType(AlertDialog)),
      ).dialogTheme;
      expect(dialogTheme.backgroundColor, GlassChrome.fill(app, raised: true));
      await tester.tap(find.text(action));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    }
    expect((await svc.getSources()).single.enabled, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('oversized synced presets show a warning and can be disabled', (
    tester,
  ) async {
    final source = StreamBadgeSource(
      id: 'old',
      name: 'Old preset',
      json: jsonEncode({
        'filters': [
          for (var i = 0; i < 513; i++) {'name': 'Rule $i', 'pattern': 'x'},
        ],
      }),
    );
    SharedPreferences.setMockInitialValues({
      StreamBadgesService.sourcesKey: jsonEncode([source.toJson()]),
    });
    final svc = StreamBadgesService.instance;
    svc.resetProfileScope();
    addTearDown(svc.resetProfileScope);
    await tester.pumpWidget(
      const MaterialApp(home: StreamBadgesSettingsPage()),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Too many active badge rules'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await svc.setSourceEnabled('old', false);
    await tester.pumpAndSettle();
    expect(find.textContaining('Too many active badge rules'), findsNothing);
    expect((await svc.getSources()).single.enabled, false);
    expect(tester.takeException(), isNull);
  });

  testWidgets('corrupt presets offer recovery instead of continuous loading', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      StreamBadgesService.sourcesKey: 'broken',
    });
    StreamBadgesService.instance.resetProfileScope();
    await tester.pumpWidget(
      const MaterialApp(home: StreamBadgesSettingsPage()),
    );
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Reset presets'), findsOneWidget);
    await tester.tap(find.text('Reset presets'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reset'));
    await tester.pumpAndSettle();
    expect(find.text('Show stream badges'), findsOneWidget);
    expect(await StreamBadgesService.instance.getSources(), isEmpty);
    expect(tester.takeException(), isNull);
  });
}
