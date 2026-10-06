import 'package:debrify/models/stremio_addon.dart';
import 'package:debrify/screens/reels_screen.dart';
import 'package:debrify/services/reels_feed.dart';
import 'package:debrify/services/youtube_service.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

StremioMeta title(String id, String type, {String? description}) => StremioMeta(
  id: id,
  imdbId: id,
  type: type,
  name: 'Title $id',
  genres: const ['Comedy', 'Romance'],
  description: description,
);

/// A catalog of [count] titles per type, served one page at a time.
ReelsCatalogPage catalog(int count, {int pageSize = 1}) {
  return (type, skip) async {
    final ids = [
      for (var i = skip; i < count && i < skip + pageSize; i++)
        title('tt${type[0]}$i', type),
    ];
    return (items: ids, rawCount: ids.length);
  };
}

const _clip = YoutubeResolvedStreams(playUrl: 'https://example.com/clip.mp4');

void main() {
  setUp(() {
    ReelsFeed.resetSession();
    SharedPreferences.setMockInitialValues({});
  });

  group('ReelsFeed', () {
    test('alternates shows and films and never repeats a title', () async {
      final feed = ReelsFeed(page: catalog(4));
      final seen = <String>[];
      StremioMeta? item;
      while ((item = await feed.next()) != null) {
        seen.add('${item!.type}:${item.id}');
      }
      expect(seen.length, 8);
      expect(seen.toSet().length, 8);
      expect(seen.take(4).map((s) => s.split(':').first).toList(), [
        'series',
        'movie',
        'series',
        'movie',
      ]);
    });

    test('a new feed in the same session skips what was shown', () async {
      final first = ReelsFeed(page: catalog(2));
      final shown = {for (var i = 0; i < 4; i++) (await first.next())!.id};
      final second = ReelsFeed(page: catalog(2));
      expect(await second.next(), isNull);
      expect(shown.length, 4);
    });

    test('titles without an IMDb id are skipped', () async {
      final feed = ReelsFeed(
        page: (type, skip) async => skip > 0
            ? (items: <StremioMeta>[], rawCount: 0)
            : (
                items: [
                  StremioMeta(id: 'local:1', type: type, name: 'No id'),
                  title('tt${type}1', type),
                ],
                rawCount: 2,
              ),
      );
      final item = await feed.next();
      expect(item?.effectiveImdbId, isNotNull);
    });
  });

  group('ReelsScreen', () {
    Widget host({
      required ReelsFeed feed,
      Future<YoutubeResolvedStreams?> Function(StremioMeta)? resolver,
    }) => MaterialApp(
      home: AppThemeScope(
        theme: AppThemes.legacy,
        child: Scaffold(
          body: ReelsScreen(
            feed: feed,
            resolver: resolver ?? (_) async => _clip,
            details: (_) async => null,
            playerBuilder: (p) => ColoredBox(
              key: ValueKey('player:${p.item.id}:${p.active}:${p.volume}'),
              color: Colors.black,
            ),
          ),
        ),
      ),
    );

    testWidgets('a reel shows its title, genres and a clamped description', (
      tester,
    ) async {
      final long = List.filled(40, 'A long description of the show.').join(' ');
      final feed = ReelsFeed(
        page: (type, skip) async => skip > 0
            ? (items: <StremioMeta>[], rawCount: 0)
            : (
                items: [title('tt${type}1', type, description: long)],
                rawCount: 1,
              ),
      );
      await tester.pumpWidget(host(feed: feed));
      await tester.pumpAndSettle();

      expect(find.text('Title ttseries1'), findsOneWidget);
      expect(find.text('Comedy • Romance'), findsOneWidget);
      // The active reel plays, with sound.
      expect(
        find.byKey(const ValueKey('player:ttseries1:true:100.0')),
        findsOneWidget,
      );
      // Description clamped with MORE; tapping expands to LESS.
      expect(find.textContaining('MORE', findRichText: true), findsOneWidget);
      await tester.tap(find.textContaining('MORE', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.textContaining('LESS', findRichText: true), findsOneWidget);
    });

    testWidgets('mute and My Watchlist toggle from the rail', (tester) async {
      await tester.pumpWidget(host(feed: ReelsFeed(page: catalog(2))));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Mute'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Unmute'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('player:tts0:true:0.0')),
        findsOneWidget,
      );
      // Sound back on for the next test's reels.
      await tester.tap(find.byTooltip('Unmute'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add to My Watchlist'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove from My Watchlist'), findsOneWidget);
      expect(find.text('Added to My Watchlist'), findsOneWidget);
    });

    testWidgets('swiping up moves to the next reel; titles without a clip '
        'never appear', (tester) async {
      await tester.pumpWidget(
        host(
          feed: ReelsFeed(page: catalog(3)),
          // No clip for the first film.
          resolver: (item) async => item.id == 'ttm0' ? null : _clip,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Title tts0'), findsOneWidget);

      await tester.fling(find.byType(PageView), const Offset(0, -500), 2000);
      await tester.pumpAndSettle();
      // ttm0 had no clip, so the next reel is the following show.
      expect(find.text('Title ttm0'), findsNothing);
      expect(find.text('Title tts1'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('player:tts1:true:100.0')),
        findsOneWidget,
      );
    });

    testWidgets('pulling the first reel down swaps it for a new title', (
      tester,
    ) async {
      await tester.pumpWidget(host(feed: ReelsFeed(page: catalog(4))));
      await tester.pumpAndSettle();
      expect(find.text('Title tts0'), findsOneWidget);

      await tester.drag(find.byType(PageView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(find.text('Title tts0'), findsNothing);
      expect(find.byType(PageView), findsOneWidget);
    });
  });
}
