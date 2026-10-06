import 'dart:async';

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

    test(
      'startup searches beyond six titles and queues confirmed clips',
      () async {
        final tmdb = FakeTmdb();
        var checked = 0;
        final feed = ReelsFeed(
          configured: true,
          language: 'en-US',
          random: math.Random(1),
          get: (path, query) async {
            final data = await tmdb.get(path, query);
            if (!path.endsWith('/popular') && ++checked <= 7) {
              data['videos'] = {'results': []};
            }
            return data;
          },
        );
        expect(await feed.take(1), hasLength(1));
        expect(checked, 8);
        expect(feed.lastRequestFailed, isFalse);
      },
    );

    test(
      'transient failures preserve candidates for a successful retry',
      () async {
        final tmdb = FakeTmdb();
        var offline = true;
        final feed = ReelsFeed(
          configured: true,
          language: 'en-US',
          random: math.Random(1),
          get: (path, query) async {
            if (offline && !path.endsWith('/popular')) {
              throw StateError('offline');
            }
            return tmdb.get(path, query);
          },
        );
        expect(await feed.take(1), isEmpty);
        expect(feed.lastRequestFailed, isTrue);
        offline = false;
        expect(await feed.take(1), hasLength(1));
        expect(feed.lastRequestFailed, isFalse);
      },
    );

    test(
      'continuous playback cycles after genuine catalog exhaustion',
      () async {
        final feed = feedFor(FakeTmdb());
        final titles = <ReelTitle>[];
        for (var i = 0; i < 40; i++) {
          final next = await feed.take(1, allowRepeat: true);
          expect(next, hasLength(1));
          titles.add(next.single);
        }
        expect(titles.take(8).map((t) => t.item.id).toSet(), hasLength(8));
        expect(titles, hasLength(40));
      },
    );

    test(
      'catalog replay picks another scene when the title has more clips',
      () async {
        final tmdb = FakeTmdb();
        final feed = ReelsFeed(
          configured: true,
          language: 'en-US',
          random: math.Random(1),
          get: (path, query) async {
            final data = await tmdb.get(path, query);
            if (!path.endsWith('/popular')) {
              final id = path.split('/').last;
              (data['videos']['results'] as List).add({
                'site': 'YouTube',
                'type': 'Clip',
                'official': true,
                'key': 'more${id.padLeft(7, '0')}',
                'name': 'Another scene',
              });
            }
            return data;
          },
        );
        final first = await feed.take(8, allowRepeat: true);
        final original = {
          for (final title in first) title.item.id: title.clipKey,
        };
        final replay = await feed.take(8, allowRepeat: true);
        expect(replay, hasLength(8));
        for (final title in replay) {
          expect(title.clipKey, isNot(original[title.item.id]));
        }
      },
    );

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
      bool floatingNav = false,
      void Function(ReelPlayback)? onPlayer,
    }) => MaterialApp(
      home: AppThemeScope(
        theme: AppThemes.legacy,
        child: Scaffold(
          body: ReelsScreen(
            feed: feed,
            floatingNav: floatingNav,
            resolver:
                resolver ??
                (key) async {
                  resolved.add(key);
                  return _clip;
                },
            playerBuilder: (p) {
              onPlayer?.call(p);
              return ColoredBox(
                key: ValueKey(
                  'player:${p.item.id}:${p.active}:${p.volume}:'
                  '${p.streams != null}:${p.paused}',
                ),
                color: Colors.black,
              );
            },
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
        if (key is ValueKey<String> && key.value.split(':')[2] == 'true') {
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
      expect(find.byTooltip('Close description'), findsOneWidget);
      await tester.tap(find.byTooltip('Close description'));
      await tester.pumpAndSettle();
      // The collapsed description must pass vertical swipes to the feed.
      await tester.fling(find.text('MORE'), const Offset(0, -400), 2000);
      await tester.pumpAndSettle();
      expect(activeId(tester), isNot(id));
    });

    testWidgets('action rail only clears navigation in floating mode', (
      tester,
    ) async {
      final feed = feedFor(FakeTmdb());
      for (final floating in [false, true, false]) {
        await tester.pumpWidget(host(feed, floatingNav: floating));
        await tester.pumpAndSettle();
        final rail = tester.widget<Positioned>(
          find
              .ancestor(
                of: find.byTooltip('Mute'),
                matching: find.byType(Positioned),
              )
              .first,
        );
        expect(rail.bottom, floating ? 104 : 24);
      }
      await tester.pumpWidget(const SizedBox());
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

    testWidgets('a pending look-ahead request does not block a later swipe', (
      tester,
    ) async {
      final pending = Completer<YoutubeResolvedStreams?>();
      var calls = 0;
      await tester.pumpWidget(
        host(
          feedFor(FakeTmdb()),
          resolver: (key) {
            resolved.add(key);
            calls++;
            return calls == 2 ? pending.future : Future.value(_clip);
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(resolved, hasLength(4));
      // Jump past the still-pending second clip. The new fourth look-ahead
      // request must start immediately, without waiting for that stale lookup.
      final pages = tester.widget<PageView>(find.byType(PageView));
      pages.controller!.jumpToPage(2);
      await tester.pumpAndSettle();
      expect(resolved.length, greaterThan(4));
      expect(playing(activeId(tester)!), findsOneWidget);
      pending.complete(_clip);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
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

    testWidgets(
      'failed clips never advance or prevent going back; retry stays put',
      (tester) async {
        var recover = false;
        await tester.pumpWidget(
          host(
            feedFor(FakeTmdb()),
            resolver: (key) async {
              resolved.add(key);
              return recover ? _clip : null;
            },
          ),
        );
        await tester.pumpAndSettle();
        final controller = tester
            .widget<PageView>(find.byType(PageView))
            .controller!;
        final first = activeId(tester)!;
        expect(controller.page, 0);
        expect(find.text('Retry clip'), findsOneWidget);
        await tester.fling(find.byType(PageView), const Offset(0, -500), 10000);
        await tester.pumpAndSettle();
        expect(controller.page, 1);
        await tester.fling(find.byType(PageView), const Offset(0, 500), 10000);
        await tester.pumpAndSettle();
        expect(controller.page, 0);
        expect(activeId(tester), first);
        recover = true;
        await tester.tap(find.text('Retry clip'));
        await tester.pumpAndSettle();
        expect(controller.page, 0);
        expect(playing(first), findsOneWidget);
      },
    );

    testWidgets(
      'long and fast gestures move exactly one page in both directions',
      (tester) async {
        await tester.pumpWidget(host(feedFor(FakeTmdb())));
        await tester.pumpAndSettle();
        final controller = tester
            .widget<PageView>(find.byType(PageView))
            .controller!;
        final gesture = await tester.startGesture(const Offset(200, 450));
        for (var i = 0; i < 5; i++) {
          await gesture.moveBy(const Offset(0, -400));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await gesture.up();
        await tester.pumpAndSettle();
        expect(controller.page, 1);
        await tester.fling(find.byType(PageView), const Offset(0, -500), 10000);
        await tester.pumpAndSettle();
        expect(controller.page, 2);
        await tester.fling(find.byType(PageView), const Offset(0, 500), 10000);
        await tester.pumpAndSettle();
        expect(controller.page, 1);
      },
    );

    testWidgets(
      'late player errors cannot break a retried clip or change the page',
      (tester) async {
        VoidCallback? staleFailure;
        await tester.pumpWidget(
          host(
            feedFor(FakeTmdb()),
            onPlayer: (playback) {
              if (playback.active && playback.streams != null) {
                staleFailure ??= playback.onPlaybackFailed;
              }
            },
          ),
        );
        await tester.pumpAndSettle();
        final first = activeId(tester)!;
        staleFailure!();
        await tester.pumpAndSettle();
        expect(find.text('Retry clip'), findsOneWidget);
        await tester.tap(find.text('Retry clip'));
        await tester.pumpAndSettle();
        expect(playing(first), findsOneWidget);
        staleFailure!();
        await tester.pumpAndSettle();
        expect(playing(first), findsOneWidget);
        expect(
          tester.widget<PageView>(find.byType(PageView)).controller!.page,
          0,
        );
      },
    );

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

    testWidgets('empty feed retries after a connection failure', (
      tester,
    ) async {
      final tmdb = FakeTmdb();
      var offline = true;
      final feed = ReelsFeed(
        configured: true,
        language: 'en-US',
        random: math.Random(1),
        get: (path, query) async {
          if (offline) throw StateError('offline');
          return tmdb.get(path, query);
        },
      );
      await tester.pumpWidget(host(feed));
      await tester.pumpAndSettle();
      expect(find.text('Retry feed'), findsOneWidget);
      offline = false;
      await tester.tap(find.text('Retry feed'));
      await tester.pumpAndSettle();
      expect(playing(activeId(tester)!), findsOneWidget);
      expect(find.text('Retry feed'), findsNothing);
    });

    testWidgets(
      'a sparse search window keeps scanning instead of ending the feed',
      (tester) async {
        final tmdb = FakeTmdb();
        var checked = 0;
        final feed = ReelsFeed(
          configured: true,
          language: 'en-US',
          random: math.Random(1),
          get: (path, query) async {
            if (path.endsWith('/popular')) {
              final page = int.parse(query['page']!);
              return {
                'total_pages': 1,
                'results': page == 1 && path.startsWith('movie')
                    ? [
                        for (var i = 0; i < 80; i++) {'id': 3000 + i},
                      ]
                    : [],
              };
            }
            final data = await tmdb.get(path, query);
            if (++checked <= 70) data['videos'] = {'results': []};
            return data;
          },
        );
        await tester.pumpWidget(host(feed));
        await tester.pumpAndSettle();
        expect(checked, greaterThan(64));
        expect(playing(activeId(tester)!), findsOneWidget);
        expect(find.text('No clips right now'), findsNothing);
      },
    );

    testWidgets('without TMDB it says so instead of spinning', (tester) async {
      await tester.pumpWidget(host(feedFor(FakeTmdb(), configured: false)));
      await tester.pumpAndSettle();
      expect(find.text('Clips need TMDB'), findsOneWidget);
    });
  });
}
