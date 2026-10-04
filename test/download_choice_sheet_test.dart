import 'package:debrify/services/storage_service.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/widgets/detail/download_choice_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late int autoCalls, manualCalls;
  late bool autoResult;

  Future<void> pumpButton(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            AppThemeScope(theme: AppThemes.legacy, child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => runDownloadButton(
                context,
                title: 'Some Movie',
                isTelevision: false,
                auto: () async {
                  autoCalls++;
                  return autoResult;
                },
                manual: () => manualCalls++,
              ),
              child: const Text('Download'),
            ),
          ),
        ),
      ),
    );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    autoCalls = 0;
    manualCalls = 0;
    autoResult = true;
  });

  testWidgets('asks by default; turning off Always ask remembers the pick', (
    tester,
  ) async {
    await pumpButton(tester);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.text('Download automatically'), findsOneWidget);
    expect(find.text('Always ask'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download automatically'));
    await tester.pumpAndSettle();
    expect(autoCalls, 1);
    expect(await StorageService.getDownloadButtonAlwaysAsk(), isFalse);
    expect(await StorageService.getDownloadButtonMode(), 'auto');

    // Next press goes straight to the remembered choice.
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.text('Download automatically'), findsNothing);
    expect(autoCalls, 2);
    expect(manualCalls, 0);
  });

  testWidgets('auto finding nothing falls back to the source list', (
    tester,
  ) async {
    await StorageService.setDownloadButtonAlwaysAsk(false);
    await StorageService.setDownloadButtonMode('auto');
    autoResult = false;
    await pumpButton(tester);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(autoCalls, 1);
    expect(manualCalls, 1);
  });

  testWidgets('manual choice opens the source list', (tester) async {
    await pumpButton(tester);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a source'));
    await tester.pumpAndSettle();
    expect(manualCalls, 1);
    expect(autoCalls, 0);
    expect(await StorageService.getDownloadButtonAlwaysAsk(), isTrue);
  });
}
