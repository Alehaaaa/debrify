import 'dart:convert';
import 'package:debrify/services/watch_history_sync_service.dart';
import 'package:debrify/services/storage_service.dart';
import 'package:debrify/services/media_server_watch_sync.dart';
import 'package:debrify/services/media_server_client.dart';
import 'package:debrify/models/media_server.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  test('clearing resume state keeps episode completion history', () async {
    await StorageService.markEpisodeAsFinished(
      seriesTitle: 'Old show',
      imdbId: 'tt1234567',
      season: 1,
      episode: 1,
      recoveryUpdatedAtMs: 1234,
    );
    await StorageService.clearPlaybackStateByImdbId(
      'tt1234567',
      preserveFinishedEpisodes: true,
    );
    expect(await StorageService.getCompletedEpisodeHistory(), hasLength(1));
    expect(
      await StorageService.getLastPlayedEpisodeByImdbId('tt1234567'),
      isNull,
    );
  });
  test(
    'old local episodes outside Continue Watching retain completion times',
    () async {
      await StorageService.markEpisodeAsFinished(
        seriesTitle: 'Old show',
        imdbId: 'tt1234567',
        season: 2,
        episode: 4,
        recoveryUpdatedAtMs: 123456,
      );
      expect(await StorageService.getContinueWatchingItems(), isEmpty);
      expect(await StorageService.getCompletedEpisodeHistory(), [
        {'id': 'tt1234567', 'season': 2, 'episode': 4, 'at': 123456},
      ]);
    },
  );
  test(
    'bulk Trakt history includes partial shows and specials without whole-show completion',
    () {
      final rows = WatchHistorySyncService.parseTrakt(
        [
          {
            'movie': {
              'ids': {'imdb': 'tt1234567'},
            },
            'last_watched_at': '2020-01-01T00:00:00Z',
          },
        ],
        [
          {
            'show': {
              'ids': {'imdb': 'tt7654321'},
            },
            'seasons': [
              {
                'number': 0,
                'episodes': [
                  {'number': 2, 'last_watched_at': '2021-01-01T00:00:00Z'},
                ],
              },
              {
                'number': 3,
                'episodes': [
                  {'number': 5},
                ],
              },
            ],
          },
        ],
      );
      expect(rows, hasLength(3));
      expect(rows[0].at, DateTime.utc(2020).millisecondsSinceEpoch);
      expect(rows[1].season, 0);
      expect(rows[1].episode, 2);
      expect(rows[2].at, isNull);
      expect(
        rows.where((r) => r.type == 'series').every((r) => r.episode != null),
        true,
      );
    },
  );
  test('missing Trakt episode history is not interpreted as empty', () {
    expect(
      () => WatchHistorySyncService.parseTrakt([], [
        {
          'show': {
            'ids': {'imdb': 'tt1234567'},
          },
        },
      ]),
      throwsFormatException,
    );
  });
  test('unified tracker sync includes provider watch sync', () async {
    expect(await MediaServerWatchSync.enabled(), false);
    await StorageService.setSyncAllContinueWatching(true);
    expect(await MediaServerWatchSync.enabled(), true);
    await StorageService.setSyncAllContinueWatching(false);
    expect(await MediaServerWatchSync.enabled(), false);
  });
  for (final kind in MediaServerKind.values) {
    test(
      '${kind.label} history writes preserve dates without playback sessions',
      () async {
        final requests = <http.Request>[];
        final client = MediaServerClient(
          client: MockClient((request) async {
            requests.add(request);
            return http.Response('', 204);
          }),
        );
        final account = MediaServerAccount(
          kind: kind,
          baseUrl: 'https://server.example/base/',
          userId: 'user1',
          token: 'secret',
          serverId: 'server1',
          deviceId: 'device1',
        );
        var checks = 0;
        await client.setHistoryWatched(
          account,
          'movie1',
          true,
          at: DateTime.utc(2020, 3, 2),
          authorize: () async {
            checks++;
          },
        );
        await client.setHistoryWatched(
          account,
          'movie1',
          false,
          authorize: () async {
            checks++;
          },
        );
        expect(requests.map((r) => r.method), ['POST', 'DELETE']);
        expect(
          requests.every(
            (r) => r.url.path == '/base/Users/user1/PlayedItems/movie1',
          ),
          true,
        );
        expect(
          requests.first.url.queryParameters['DatePlayed'],
          '2020-03-02T00:00:00.000Z',
        );
        expect(requests.last.url.queryParameters, isEmpty);
        expect(checks, 4);
        client.close();
      },
    );
    test(
      '${kind.label} history inventory is recursive, paged and includes IDs',
      () async {
        final client = MediaServerClient(
          client: MockClient((request) async {
            expect(request.url.queryParameters['Recursive'], 'true');
            expect(request.url.queryParameters['StartIndex'], '60');
            expect(
              request.url.queryParameters['Fields'],
              contains('ProviderIds'),
            );
            expect(request.url.queryParameters['Filters'], isNull);
            return http.Response(
              jsonEncode({'Items': [], 'TotalRecordCount': 60}),
              200,
            );
          }),
        );
        final account = MediaServerAccount(
          kind: kind,
          baseUrl: 'https://server.example/',
          userId: 'user1',
          token: 'secret',
          serverId: 'server1',
          deviceId: 'device1',
        );
        expect(
          (await client.library(
            account,
            mode: 'history',
            offset: 60,
          )).nextOffset,
          isNull,
        );
        client.close();
      },
    );
  }
}
