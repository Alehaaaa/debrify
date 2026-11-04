import 'dart:convert';

import 'package:debrify/screens/settings/stremio_addons_page.dart';
import 'package:debrify/services/stremio_service.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/theme/glass_chrome.dart';
import 'package:debrify/theme/premium_looks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Stremio addon controls and reopened popup follow appearance', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    StremioService.instance.invalidateCache();
    await StremioService.instance.importAddonsFromJson(
      jsonEncode({
        'addons': [
          {
            'manifest': {
              'id': 'org.example.frosted',
              'name': 'Example Streams',
              'version': '1.0.0',
              'resources': ['stream'],
              'types': ['movie'],
            },
            'transportUrl': 'https://example.com/manifest.json',
          },
        ],
      }),
    );

    Widget host(AppTheme app) => AppThemeScope(
      theme: app,
      child: const MaterialApp(
        home: Scaffold(body: StremioAddonsPageContent()),
      ),
    );

    final glass = PremiumLooks.glass.build();
    await tester.pumpWidget(host(glass));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Example Streams'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.text('Example Streams'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .join(' | '),
    );
    final frostedCard = tester.widget<AnimatedContainer>(
      find
          .ancestor(
            of: find.text('Example Streams'),
            matching: find.byType(AnimatedContainer),
          )
          .first,
    );
    expect(
      frostedCard.decoration,
      GlassChrome.decoration(glass, radius: BorderRadius.circular(16)),
    );
    await tester.tap(find.text('Example Streams'));
    await tester.pumpAndSettle();
    expect(find.text('View Details'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await tester.pumpWidget(host(AppThemes.legacy));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Example Streams'));
    await tester.pumpAndSettle();
    expect(find.text('View Details'), findsOneWidget);
  });
}
