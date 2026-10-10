import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:debrify/screens/settings/widgets/settings_widgets.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/theme/premium_looks.dart';

void main() {
  Widget screen(AppTheme theme, {bool highContrast = false}) => AppThemeScope(
    theme: theme,
    child: MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(highContrast: highContrast),
        child: Scaffold(
          body: SettingsSection(
            title: 'Appearance',
            children: const [ListTile(title: Text('Glass setting'))],
          ),
        ),
      ),
    ),
  );

  testWidgets('glass appearance frosts the grouped settings surface', (
    tester,
  ) async {
    await tester.pumpWidget(screen(PremiumLooks.glass.build()));

    expect(find.text('Glass setting'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('high contrast makes the glass panel solid', (tester) async {
    await tester.pumpWidget(
      screen(PremiumLooks.glass.build(), highContrast: true),
    );

    expect(find.text('Glass setting'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });

  testWidgets('legacy settings keep their unblurred grouping', (tester) async {
    await tester.pumpWidget(screen(AppThemes.legacy));

    expect(find.text('Glass setting'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });
}
