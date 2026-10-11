import 'package:debrify/screens/settings/recordings_page.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/theme/premium_looks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'recordings hub follows appearance changes and remains navigable',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      Widget host(AppTheme theme) => AppThemeScope(
        theme: theme,
        child: const MaterialApp(home: RecordingsPage()),
      );

      final glass = PremiumLooks.glass.build();
      await tester.pumpWidget(host(glass));
      await tester.pump();
      expect(find.text('Recordings'), findsOneWidget);
      expect(
        tester.widget<Scaffold>(find.byType(Scaffold)).backgroundColor,
        glass.core.ground,
      );
      expect(
        tester.widget<Text>(find.text('Recordings')).style!.color,
        glass.core.tx,
      );
      expect(find.byTooltip('Back'), findsOneWidget);
      expect(find.text('Schedule'), findsOneWidget);

      await tester.pumpWidget(host(AppThemes.legacy));
      await tester.pump();
      expect(
        tester.widget<Text>(find.text('Recordings')).style!.color,
        Colors.white,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
