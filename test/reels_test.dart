import 'dart:math' as math;

import 'package:debrify/screens/reels_screen.dart';
import 'package:debrify/services/reels_feed.dart';
import 'package:debrify/services/youtube_service.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A fake TMDB: two pages of two titles per type. Titles whose id is in
/// [noClip] only have a trailer. Every request is recorded.
class FakeTmdb {
  FakeTmdb({this.noClip = const {}, this.description});

  final Set<int> noClip;
  final String? description;
  final requests = <String>[];

  int get detailRequests =>
      requests.where((r) => RegExp(r'^(movie|tv)/\d+$').hasMatch(r)).length;
  int get listRequests => requests.where((r) => r.endsWith('/popular')).length;

  Future<Map<String, dynamic>> get(
    String path,
    Map<String, String> query,
  ) async {
    requests.add(path);
    final list = RegExp(r'^(movie|tv)/popular$').firstMatch(path);
    if (list != null) {
      final type = list.group(1)!;
      final page = int.parse(query['page']!);
      final base = type == 'movie' ? 1000 : 2000;
      return {
        'total_pages': 2,
        'results': page > 2
            ? []
            : [
                for (var i = 0; i < 2; i++)
                  {'id': base + page * 10 + i, 'title': 'x'},
              ],
      };
    }
    final id = int.parse(path.split('/').last);
    final movie = path.startsWith('movie/');
    return {
      movie ? 'title' : 'name': 'Title $id',
      movie ? 'release_date' : 'first_air_date': '2001-02-03',
      'overview': description ?? 'About $id.',
      'genres': [
        {'id': 1, 'name': 'Comedy'},
        {'id': 2, 'name': 'Romance'},
      ],
      'external_ids': {'imdb_id': 'tt$id'},
      'videos': {
        'results': [
          {'site': 'YouTube', 'type': 'Trailer', 'key': 'trailer0000'},
          if (!noClip.contains(id))
            {
              'site': 'YouTube',
              'type': 'Clip',
              'key': 'clip${id.toString().padLeft(7, '0')}',
              'name': "'Scene $id'",
              'official': true,
            },
        ],
      },
    };
  }
}

const _clip = YoutubeResolvedStreams(playUrl: 'https://example.com/clip.mp4');

void main() {
  setUp(() {
    ReelsFeed.resetSession();
    SharedPreferences.setMockInitialValues({});
  });

  ReelsFeed feedFor(FakeTmdb tmdb, {bool configured = true}) => ReelsFeed(
    get: tmdb.get,
    configured: configured,
    language: 'en-US',
    random: math.Random(1),
  );

  group('ReelsFeed', () {
    test('only official clips are picked — never trailers or teasers', () {
      final clip = ReelsFeed.pickClip({
        'results': [
          {'site': 'YouTube', 'type': 'Trailer', 'key': 'aaaaaaaaaaa'},
          {'site': 'YouTube', 'type': 'Teaser', 'key': 'bbbbbbbbbbb'},
          {'site': 'Vimeo', 'type': 'Clip', 'key': 'ccccccccccc'},
          {
            'site': 'YouTube',
            'type': 'Clip',
            'key': 'ddddddddddd',
            'name': 'fan',
          },
          {
            'site': 'YouTube',
            'type': 'Clip',
            'key': 'eeeeeeeeeee',
            'name': 'official',
            'official': true,
          },
        ],
      }, math.Random(1));
      expect(clip?.key, 'eeeeeeeeeee');
      expect(
        ReelsFeed.pickClip({
          'results': [
            {'site': 'YouTube', 'type': 'Trailer', 'key': 'aaaaaaaaaaa'},
          ],
        }, math.Random(1)),
        isNull,
      );
    });

    test('one details request per title; titles without a clip are '
        'dropped; movies and shows alternate', () async {
      final tmdb = FakeTmdb(noClip: {1011, 1021});
      final feed = feedFor(tmdb);
      final titles = <ReelTitle>[];
      List<ReelTitle> batch;
      while ((batch = await feed.take(3)).isNotEmpty) {
        titles.addAll(batch);
      }
      final ids = titles.map((t) => t.item.id).toList();
      // Every title had exactly one details request, clip or not.
      expect(tmdb.detailRequests, 8);
      expect(tmdb.listRequests, lessThanOrEqualTo(6));
      // The two movies without a clip never made it.
      expect(ids, isNot(contains('tt1011')));
      expect(ids, isNot(contains('tt1021')));
      expect(ids.toSet().length, ids.length);
      expect(titles.where((t) => t.item.type == 'series').length, 4);
      // A reel carries everything it shows from that one answer.
      final first = titles.first;
      expect(first.clipKey, startsWith('clip'));
      expect(first.clipName, startsWith("'Scene"));
      expect(first.item.genres, ['Comedy', 'Romance']);
      expect(first.item.year, '2001');
      expect(first.item.imdbId, startsWith('tt'));
    });

    test('a new feed in the same session skips what was shown', () async {
      final first = feedFor(FakeTmdb());
      while ((await first.take(4)).isNotEmpty) {}
      expect(await feedFor(FakeTmdb()).take(4), isEmpty);
    });

    test('without TMDB there is nothing to ask', () async {
      final tmdb = FakeTmdb();
      expect(await feedFor(tmdb, configured: false).take(3), isEmpty);
      expect(tmdb.requests, isEmpty);
    });
  });

  group('ReelsScreen', () {
    late List<String> resolved;

    Widget host(
      ReelsFeed feed, {
      Future<YoutubeResolvedStreams?> Function(String key)? resolver,
    }) => MaterialApp(
      home: AppThemeScope(
        theme: AppThemes.legacy,
        child: Scaffold(
          body: ReelsScreen(
            feed: feed,
            resolver:
                resolver ??
                (key) async {
                  resolved.add(key);
                  return _clip;
                },
            playerBuilder: (p) => ColoredBox(
              key: ValueKey(
                'player:${p.item.id}:${p.active}:${p.volume}:'
                '${p.streams != null}:${p.paused}',
              ),
              color: Colors.black,
            ),
          ),
        ),
      ),
    );

    setUp(() => resolved = []);

    Finder playing(String id, {double volume = 100}) =>
        find.byKey(ValueKey('player:$id:true:$volume:true:false'));
    String? activeId(WidgetTester tester) {
      for (final element in find.byType(ColoredBox).evaluate()) {
        final key = element.widget.key;
        if (key is ValueKey<String> && key.value.contains(':true:')) {
          return key.value.split(':')[1];
        }
      }
      return null;
    }

    testWidgets('a reel shows the clip name, genres and a clamped '
        'description', (tester) async {
      final long = List.filled(40, 'A long description.').join(' ');
      await tester.pumpWidget(host(feedFor(FakeTmdb(description: long))));
      await tester.pumpAndSettle();
      final id = activeId(tester)!;
      expect(playing(id), findsOneWidget);
      final number = id.substring(2);
      expect(find.text('Title $number'), findsOneWidget);
      expect(find.text("'Scene $number'"), findsOneWidget);
      expect(find.text('Comedy • Romance'), findsOneWidget);
      expect(find.textContaining('MORE', findRichText: true), findsOneWidget);
      await tester.tap(find.textContaining('MORE', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.textContaining('LESS', findRichText: true), findsOneWidget);
    });

    testWidgets('clips are ready three reels ahead, and the window moves '
        'with every swipe', (tester) async {
      await tester.pumpWidget(host(feedFor(FakeTmdb())));
      await tester.pumpAndSettle();
      // The reel on screen plus the next three.
      expect(resolved.length, 4);

      await tester.fling(find.byType(PageView), const Offset(0, -500), 2000);
      await tester.pumpAndSettle();
      // Landed on a reel that was already resolved — it plays at once — and
      // one more joins the window.
      expect(playing(activeId(tester)!), findsOneWidget);
      expect(resolved.length, 5);
      expect(resolved.toSet().length, resolved.length);
    });

    testWidgets('tapping the video pauses and resumes; a new reel plays', (
      tester,
    ) async {
      await tester.pumpWidget(host(feedFor(FakeTmdb())));
      await tester.pumpAndSettle();
      final id = activeId(tester)!;

      await tester.tapAt(const Offset(200, 150));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey('player:$id:true:100.0:true:true')),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.play_arrow_rounded), findsOneWidget);

      await tester.tapAt(const Offset(200, 150));
      await tester.pumpAndSettle();
      expect(playing(id), findsOneWidget);

      // Paused, then swiped on: the next reel starts playing.
      await tester.tapAt(const Offset(200, 150));
      await tester.pumpAndSettle();
      await tester.fling(find.byType(PageView), const Offset(0, -500), 2000);
      await tester.pumpAndSettle();
      expect(playing(activeId(tester)!), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow_rounded), findsNothing);
    });

    testWidgets('a clip that can\'t play moves on to the next reel', (
      tester,
    ) async {
      var first = true;
      await tester.pumpWidget(
        host(
          feedFor(FakeTmdb()),
          resolver: (key) async {
            if (first) {
              first = false;
              return null;
            }
            return _clip;
          },
        ),
      );
      await tester.pumpAndSettle();
      final page = tester.widget<PageView>(find.byType(PageView));
      expect(page.controller!.page, 1);
      expect(activeId(tester), isNotNull);
    });

    testWidgets('mute and My Watchlist toggle from the rail', (tester) async {
      await tester.pumpWidget(host(feedFor(FakeTmdb())));
      await tester.pumpAndSettle();
      final id = activeId(tester)!;

      await tester.tap(find.byTooltip('Mute'));
      await tester.pumpAndSettle();
      expect(playing(id, volume: 0), findsOneWidget);
      await tester.tap(find.byTooltip('Unmute'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add to My Watchlist'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Remove from My Watchlist'), findsOneWidget);
      expect(find.text('Added to My Watchlist'), findsOneWidget);
    });

    testWidgets('pulling the first reel down swaps it for a new title', (
      tester,
    ) async {
      await tester.pumpWidget(host(feedFor(FakeTmdb())));
      await tester.pumpAndSettle();
      final before = activeId(tester);
      await tester.drag(find.byType(PageView), const Offset(0, 300));
      await tester.pumpAndSettle();
      expect(activeId(tester), isNot(before));
    });

    testWidgets('without TMDB it says so instead of spinning', (tester) async {
      await tester.pumpWidget(host(feedFor(FakeTmdb(), configured: false)));
      await tester.pumpAndSettle();
      expect(find.text('Clips need TMDB'), findsOneWidget);
    });
  });
}
