import 'dart:async';
import 'dart:math';

import 'package:debrify/models/stremio_addon.dart';
import 'package:debrify/services/reels_feed.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reels_test.dart' show FakeTmdb;

void main() {
  setUp(ReelsFeed.resetSession);

  test('ready queue alternates formats and avoids repeating a genre', () async {
    final tmdb = FakeTmdb();
    final feed = ReelsFeed(
      configured: true,
      language: 'en-US',
      random: Random(1),
      get: (path, query) async {
        final data = await tmdb.get(path, query);
        if (!path.endsWith('/popular')) {
          final id = int.parse(path.split('/').last);
          data['genres'] = [
            {'name': id.isEven ? 'Comedy' : 'Drama'},
          ];
        }
        return data;
      },
    );
    final titles = await feed.take(8);
    expect(titles, hasLength(8));
    for (var i = 1; i < titles.length; i++) {
      expect(titles[i].item.type, isNot(titles[i - 1].item.type));
    }
    expect(titles[1].item.genres, isNot(titles[0].item.genres));
    expect(tmdb.detailRequests, 8);
  });

  test(
    'overlapping refresh and fill share cursors without duplicate work',
    () async {
      final tmdb = FakeTmdb();
      final feed = ReelsFeed(
        get: tmdb.get,
        configured: true,
        language: 'en-US',
        random: Random(1),
      );
      final batches = await Future.wait([
        feed.take(3),
        feed.take(3),
        feed.take(2),
      ]);
      final titles = batches.expand((batch) => batch).toList();
      expect(titles, hasLength(8));
      expect(titles.map((title) => title.item.id).toSet(), hasLength(8));
      expect(tmdb.detailRequests, 8);
    },
  );

  test(
    'provider lookups are bounded and do not block the first clip',
    () async {
      final tmdb = FakeTmdb();
      final gate = Completer<void>();
      var active = 0;
      var peak = 0;
      var requests = 0;
      final finished = Completer<void>();
      final feed = ReelsFeed(
        configured: true,
        language: 'en-US',
        random: Random(1),
        sourceLoad: () async => [
          for (var i = 0; i < 12; i++)
            StremioMeta(
              id: 'tt${9000 + i}',
              imdbId: 'tt${9000 + i}',
              type: 'movie',
              name: 'Source $i',
            ),
        ],
        get: (path, query) async {
          if (!path.startsWith('find/')) return tmdb.get(path, query);
          active++;
          peak = max(peak, active);
          requests++;
          await gate.future;
          active--;
          if (requests == 12 && active == 0) finished.complete();
          return {
            'movie_results': [
              {'id': int.parse(path.substring(7))},
            ],
          };
        },
      );
      try {
        expect(
          await feed.take(1).timeout(const Duration(seconds: 2)),
          hasLength(1),
        );
        expect(requests, 4);
        expect(peak, 4);
        gate.complete();
        await finished.future.timeout(const Duration(seconds: 2));
        expect(peak, 4);
      } finally {
        if (!gate.isCompleted) gate.complete();
      }
    },
  );

  test('late provider candidates revive a depleted TMDB queue', () async {
    final tmdb = FakeTmdb(
      noClip: {1010, 1011, 1020, 1021, 2010, 2011, 2020, 2021},
    );
    final source = Completer<List<StremioMeta>>();
    final feed = ReelsFeed(
      configured: true,
      language: 'en-US',
      random: Random(1),
      sourceLoad: () => source.future,
      get: (path, query) async => path.startsWith('find/')
          ? {
              'movie_results': [
                {'id': 9000},
              ],
            }
          : tmdb.get(path, query),
    );
    expect(await feed.take(1), isEmpty);
    expect(feed.exhausted, isFalse);
    source.complete([
      const StremioMeta(
        id: 'tt9000',
        imdbId: 'tt9000',
        type: 'movie',
        name: 'Late title',
      ),
    ]);
    await Future<void>.delayed(Duration.zero);
    final titles = await feed.take(1);
    expect(titles.single.item.id, 'tt9000');
  });
}
