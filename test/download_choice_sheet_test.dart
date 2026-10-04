import 'package:debrify/services/storage_service.dart';
import 'package:debrify/services/torrent_playback_service.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/widgets/detail/download_choice_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late List<DownloadScope?> autoCalls;
  late List<(DownloadScope?, AutoDownloadResult?)> manualCalls;
  late AutoDownloadResult autoResult;

  Future<void> pumpButton(
    WidgetTester tester, {
    DownloadSeriesTarget? series,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            AppThemeScope(theme: AppThemes.legacy, child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => runDownloadButton(
                context,
                title: 'Some Title',
                isTelevision: false,
                series: series,
                auto: (scope) async {
                  autoCalls.add(scope);
                  return autoResult;
                },
                manual: (scope, why) => manualCalls.add((scope, why)),
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
    autoCalls = [];
    manualCalls = [];
    autoResult = const AutoDownloadResult.done();
  });

  testWidgets('asks by default; turning off Always ask remembers the pick', (
    tester,
  ) async {
    await pumpButton(tester);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.text('Download automatically'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download automatically'));
    await tester.pumpAndSettle();
    expect(autoCalls, [null]);
    expect(await StorageService.getDownloadButtonAlwaysAsk(), isFalse);
    expect(await StorageService.getDownloadButtonMode(), 'auto');

    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.text('Download automatically'), findsNothing);
    expect(autoCalls, [null, null]);
    expect(manualCalls, isEmpty);
  });

  testWidgets('auto finding nothing opens the list with the reason', (
    tester,
  ) async {
    await StorageService.setDownloadButtonAlwaysAsk(false);
    await StorageService.setDownloadButtonMode('auto');
    autoResult = const AutoDownloadResult(
      AutoDownloadMiss.noFilterMatch,
      filterSummary: '1080p · H.265',
    );
    await pumpButton(tester);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(manualCalls, hasLength(1));
    final note = downloadMissNote(manualCalls.single.$2!);
    expect(note.message, contains('1080p · H.265'));
    expect(note.showAll, isTrue);
  });

  testWidgets('a series picks how much to download, defaulting to the next '
      'episodes', (tester) async {
    await pumpButton(tester, series: (season: 2, episode: 4));
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.text('Episode 4'), findsOneWidget);
    expect(find.text('Episodes 4–6'), findsOneWidget);
    expect(find.text('Season 2'), findsOneWidget);
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Episodes 4–6'))
          .selected,
      isTrue,
    );

    await tester.tap(find.text('Season 2'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose a source'));
    await tester.pumpAndSettle();
    expect(manualCalls.single.$1, DownloadScope.season);
    expect(await StorageService.getDownloadSeriesScope(), 'season');
  });
}
