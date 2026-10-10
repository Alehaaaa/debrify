import 'package:debrify/services/text_brightness.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_adapter.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/theme/glass_chrome.dart';
import 'package:debrify/theme/premium_looks.dart';
import 'package:debrify/theme/widgets/glass_surface.dart';
import 'package:debrify/widgets/search_source_dropdown.dart';
import 'package:debrify/widgets/see_all/see_all_random_button.dart';
import 'package:debrify/widgets/view_mode_dropdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() => AppThemeAdapter.debugUseTestTypography = true);
  tearDown(() => AppThemeAdapter.debugUseTestTypography = false);

  Widget host(AppTheme app, Widget child) => MaterialApp(
    theme: AppThemeAdapter.themed(app, TextBrightness.bright),
    home: AppThemeScope(
      theme: app,
      child: Scaffold(body: Center(child: child)),
    ),
  );

  testWidgets('search sources reuse frosted surfaces, including their popup', (
    tester,
  ) async {
    final glass = PremiumLooks.glass.build();
    Widget selector() => SearchSourceDropdown(
      selectedOption: SearchSourceOption.all(),
      options: [SearchSourceOption.all(), SearchSourceOption.keyword()],
      onChanged: (_) {},
    );

    await tester.pumpWidget(host(glass, selector()));
    final trigger = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer).first,
    );
    expect(
      (trigger.decoration! as BoxDecoration).color,
      GlassChrome.fill(glass),
    );
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(find.byType(GlassSurface), findsOneWidget);

    await tester.pumpWidget(host(AppThemes.legacy, selector()));
    await tester.pumpAndSettle();
    expect(find.byType(GlassSurface), findsNothing);
  });

  testWidgets(
    'download view mode and Discover action use the same frosted fill',
    (tester) async {
      final glass = PremiumLooks.glass.build();
      await tester.pumpWidget(
        host(
          glass,
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ViewModeDropdown(
                currentMode: FolderViewMode.raw,
                onModeChanged: (_) {},
              ),
              SeeAllRandomButton(onPressed: () {}),
            ],
          ),
        ),
      );
      final colors = tester
          .widgetList<Container>(find.byType(Container))
          .map((w) => w.decoration)
          .whereType<BoxDecoration>()
          .map((decoration) => decoration.color)
          .toList();
      expect(colors, contains(GlassChrome.fill(glass)));
    },
  );
}
