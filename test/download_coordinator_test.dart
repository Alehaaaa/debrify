import 'package:debrify/models/sources_notice.dart';
import 'package:debrify/services/downloads/download_coordinator.dart';
import 'package:debrify/services/downloads/download_outcome.dart';
import 'package:debrify/services/downloads/download_preferences.dart';
import 'package:debrify/services/downloads/download_request.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late List<DownloadScope?> autoCalls;
  late List<(DownloadScope?, SourcesNotice?)> sourceCalls;
  late DownloadOutcome outcome;

  const movie = DownloadRequest.title(id: 'tt1', title: 'Some Movie');
  const show = DownloadRequest.series(
    id: 'tt2',
    title: 'Some Show',
    season: 2,
    episode: 4,
  );

  Future<void> pumpButton(WidgetTester tester, DownloadRequest request) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            AppThemeScope(theme: AppThemes.legacy, child: child!),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => DownloadCoordinator.start(
                context,
                request: request,
                isTelevision: false,
                auto: (scope) async {
                  autoCalls.add(scope);
                  return outcome;
                },
                openSources: (scope, notice) =>
                    sourceCalls.add((scope, notice)),
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
    sourceCalls = [];
    outcome = const DownloadOutcome.started();
  });

  testWidgets('asks by default; turning off Always ask remembers the pick', (
    tester,
  ) async {
    await pumpButton(tester, movie);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.text('Download automatically'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download automatically'));
    await tester.pumpAndSettle();
    expect(autoCalls, [null]);
    final prefs = await DownloadPreferences.load();
    expect(prefs.alwaysAsk, isFalse);
    expect(prefs.choice, DownloadChoice.auto);

    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.text('Download automatically'), findsNothing);
    expect(autoCalls, [null, null]);
    expect(sourceCalls, isEmpty);
  });

  testWidgets('automatic finding nothing opens the sources with the reason', (
    tester,
  ) async {
    await const DownloadPreferences(
      choice: DownloadChoice.auto,
      alwaysAsk: false,
    ).save();
    outcome = const DownloadOutcome.missed(
      DownloadMiss.noFilterMatch,
      filterSummary: '1080p · H.265',
    );
    await pumpButton(tester, movie);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    final notice = sourceCalls.single.$2!;
    expect(notice.message, contains('1080p · H.265'));
    expect(notice.showAll, isTrue);
  });

  testWidgets('a series picks how much, defaulting to the next episodes', (
    tester,
  ) async {
    await pumpButton(tester, show);
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();
    expect(find.text('Episode 4'), findsOneWidget);
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
    expect(sourceCalls.single.$1, DownloadScope.season);
    expect(
      (await DownloadPreferences.load()).seriesScope,
      DownloadScope.season,
    );
  });

  test('a request knows which episodes each scope covers', () {
    expect(show.wantedEpisodes(DownloadScope.episode), {4});
    expect(show.wantedEpisodes(DownloadScope.nextEpisodes), {4, 5, 6});
    expect(show.wantedEpisodes(DownloadScope.season), isNull);
    expect(show.searchEpisode(DownloadScope.season), isNull);
    expect(movie.wantedEpisodes(null), isNull);
  });
}
