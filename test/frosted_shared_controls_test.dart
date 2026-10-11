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
import 'package:debrify/screens/settings/widgets/settings_widgets.dart';
import 'package:debrify/screens/settings/widgets/sync_device_tile.dart';
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

  testWidgets('Settings dropdown and theme follow the selected glass look', (
    tester,
  ) async {
    const choices = [
      SettingsSelectOption('auto', 'Automatic'),
      SettingsSelectOption('1080', '1080p'),
    ];
    Widget selector() => Builder(
      builder: (context) => Theme(
        data: settingsPageTheme(context),
        child: SettingsSelectDropdown(
          options: choices,
          value: 'auto',
          onChanged: (_) {},
        ),
      ),
    );
    final glass = PremiumLooks.glass.build();
    await tester.pumpWidget(host(glass, selector()));
    var dropdown = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(dropdown.dropdownColor, GlassChrome.fill(glass, raised: true));
    final settingsContext = tester.element(
      find.byType(DropdownButtonFormField<String>),
    );
    expect(
      Theme.of(settingsContext).canvasColor,
      GlassChrome.fill(glass, raised: true),
    );

    await tester.pumpWidget(host(AppThemes.legacy, selector()));
    dropdown = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(dropdown.dropdownColor, AppThemes.legacy.settings.panel2);
  });

  testWidgets('Settings outlined actions and sync devices follow appearance', (
    tester,
  ) async {
    Widget controls() => Builder(
      builder: (context) => Theme(
        data: settingsPageTheme(context),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            OutlinedButton(onPressed: null, child: Text('Action')),
            SyncDeviceTile(name: 'Living room', status: 'Connected'),
          ],
        ),
      ),
    );
    final glass = PremiumLooks.glass.build();
    await tester.pumpWidget(host(glass, controls()));
    final buttonContext = tester.element(find.byType(OutlinedButton));
    final side = Theme.of(
      buttonContext,
    ).outlinedButtonTheme.style!.side!.resolve(<WidgetState>{});
    expect(side!.color, GlassChrome.edge(glass));
    final glassColors = tester
        .widgetList<Container>(find.byType(Container))
        .map((widget) => widget.decoration)
        .whereType<BoxDecoration>()
        .map((decoration) => decoration.color);
    expect(glassColors, contains(GlassChrome.fill(glass)));

    await tester.pumpWidget(host(AppThemes.legacy, controls()));
    final legacyColors = tester
        .widgetList<Container>(find.byType(Container))
        .map((widget) => widget.decoration)
        .whereType<BoxDecoration>()
        .map((decoration) => decoration.color);
    expect(legacyColors, isNot(contains(GlassChrome.fill(glass))));
  });
}
