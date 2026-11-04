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
    expect(
      tester.widget<Text>(find.text('Home Screen')).style!.color,
      frosted.core.tx,
    );
    expect(
      tester.widget<Icon>(find.byIcon(Icons.arrow_back_rounded)).color,
      frosted.settings.dim,
    );

    await tester.pumpWidget(host(AppThemes.legacy));
    expect(actionDecoration(tester).color, isNull);
    expect(
      tester.widget<Text>(find.text('Home Screen')).style!.color,
      Colors.white,
    );
  });

  testWidgets('arrange instructions adapt to frosted and classic contrast', (
    tester,
  ) async {
    Widget host(AppTheme theme) => AppThemeScope(
      theme: theme,
      child: const MaterialApp(
        home: HomeSectionsFilterPage(
          catalogTree: [],
          disabled: {},
          rowOrder: ['cw:movies'],
          isTelevision: false,
        ),
      ),
    );

    final glass = PremiumLooks.glass.build();
    await tester.pumpWidget(host(glass));
    await tester.tap(find.text('Arrange'));
    await tester.pumpAndSettle();
    final hint = find.textContaining('Drag rows into the order');
    expect(hint, findsOneWidget);
    expect(
      tester.widget<Text>(hint).style!.color,
      glass.core.tx.withValues(alpha: 0.68),
    );

    await tester.pumpWidget(host(AppThemes.legacy));
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(hint).style!.color,
      Colors.white.withValues(alpha: 0.55),
    );
  });
}
