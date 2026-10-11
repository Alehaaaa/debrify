import 'package:debrify/screens/settings/home_sections_filter_page.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/theme/glass_chrome.dart';
import 'package:debrify/theme/premium_looks.dart';
import 'package:debrify/widgets/home/home_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Home section headings retain readable contrast on glass', (
    tester,
  ) async {
    Widget host(AppTheme app) => AppThemeScope(
      theme: app,
      child: const MaterialApp(
        home: Scaffold(
          body: HomeSectionHeader(title: 'Continue watching', count: 4),
        ),
      ),
    );
    final frosted = PremiumLooks.glass.build();
    await tester.pumpWidget(host(frosted));
    expect(
      tester.widget<Text>(find.text('Continue watching')).style!.color,
      frosted.core.tx,
    );
    expect(
      tester.widget<Text>(find.text('4')).style!.color,
      frosted.core.tx.withValues(alpha: 0.52),
    );
    await tester.pumpWidget(host(AppThemes.legacy));
    expect(
      tester.widget<Text>(find.text('Continue watching')).style!.color,
      Colors.white,
    );
  });

  testWidgets('Home row manager buttons follow appearance changes', (
    tester,
  ) async {
    Widget host(AppTheme app) => AppThemeScope(
      theme: app,
      child: const MaterialApp(
        home: HomeSectionsFilterPage(
          catalogTree: [],
          disabled: {},
          isTelevision: false,
        ),
      ),
    );

    BoxDecoration actionDecoration(WidgetTester tester) {
      final label = find.text('Invert');
      final container = find
          .ancestor(of: label, matching: find.byType(Container))
          .first;
      return tester.widget<Container>(container).decoration! as BoxDecoration;
    }

    final frosted = PremiumLooks.glass.build();
    await tester.pumpWidget(host(frosted));
    expect(actionDecoration(tester).color, GlassChrome.fill(frosted));

    await tester.pumpWidget(host(AppThemes.legacy));
    expect(actionDecoration(tester).color, isNull);
  });
}
