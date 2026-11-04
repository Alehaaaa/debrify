import 'dart:convert';

import 'package:debrify/services/omdb/omdb_ratings_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, Object?> _body({
  String rt = '89%',
  String released = '14 Oct 1994',
  String year = '1994',
  String type = 'movie',
}) => {
  'Response': 'True',
  'Type': type,
  'Year': year,
  'Released': released,
  'Ratings': [
    {'Source': 'Internet Movie Database', 'Value': '9.3/10'},
    if (rt.isNotEmpty) {'Source': 'Rotten Tomatoes', 'Value': rt},
  ],
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('parsing', () {
    test('reads the Tomatometer from Ratings', () {
      expect(OmdbRatingsService.parseRottenTomatoes(_body()), 89);
      expect(OmdbRatingsService.parseRottenTomatoes(_body(rt: '')), isNull);
    });

    test('reads Metacritic and IMDb too', () {
      final body = {
        ..._body(),
        'imdbRating': '9.3',
        'Metascore': '82',
        'Ratings': [
          {'Source': 'Metacritic', 'Value': '82/100'},
        ],
      };
      expect(OmdbRatingsService.parseMetacritic(body), 82);
      expect(OmdbRatingsService.parseImdb(body), 9.3);
      final entry = OmdbCacheEntry(
        score: 89,
        metacritic: 82,
        imdb: 9.3,
        at: DateTime(2026),
      );
      final back = OmdbCacheEntry.fromJson(
        jsonDecode(jsonEncode(entry.toJson())),
      )!;
      expect([back.score, back.metacritic, back.imdb], [89, 82, 9.3]);
    });

    test('reads release dates, including pre-1970', () {
      expect(
        OmdbRatingsService.parseReleased(_body(released: '03 Sep 1954')),
        DateTime(1954, 9, 3),
      );
      expect(
        OmdbRatingsService.parseReleased(_body(released: 'N/A', year: '2001')),
        DateTime(2001),
      );
    });

    test('flags open-ended series only', () {
      expect(
        OmdbRatingsService.parseOngoing(_body(type: 'series', year: '2019–')),
        isTrue,
      );
      expect(
        OmdbRatingsService.parseOngoing(
          _body(type: 'series', year: '2008–2013'),
        ),
        isFalse,
      );
    });

    test('cache entries round-trip, pre-1970 dates included', () {
      final entry = OmdbCacheEntry(
        score: 97,
        at: DateTime(2026, 10, 1),
        released: DateTime(1954, 9, 3),
      );
      final back = OmdbCacheEntry.fromJson(
        jsonDecode(jsonEncode(entry.toJson())),
      )!;
      expect(back.score, 97);
      expect(back.released, DateTime(1954, 9, 3));
      expect(back.ongoing, isFalse);
    });
  });

  group('ttl', () {
    final now = DateTime(2026, 10, 9);
    Duration ttl(int? score, DateTime? released, {bool ongoing = false}) =>
        OmdbRatingsService.ttlFor(
          OmdbCacheEntry(
            score: score,
            at: now,
            released: released,
            ongoing: ongoing,
          ),
          now,
        );

    test('settled titles are effectively fetched once', () {
      expect(ttl(89, DateTime(1994)), const Duration(days: 365));
      expect(ttl(null, DateTime(1994)), const Duration(days: 180));
    });

    test('new releases are rechecked often', () {
      expect(ttl(70, DateTime(2026, 10, 1)), const Duration(days: 4));
      expect(ttl(null, DateTime(2026, 12, 1)), const Duration(days: 2));
    });

    test('running series refresh monthly', () {
      expect(ttl(90, DateTime(2019), ongoing: true), const Duration(days: 30));
    });
  });

  group('service', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('fetches once, shares in-flight, persists, and notifies', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        expect(request.url.queryParameters['i'], 'tt0111161');
        return http.Response(jsonEncode(_body()), 200);
      });
      final service = OmdbRatingsService(
        apiKey: 'k',
        clientFactory: () => client,
      );
      var notified = 0;
      service.addListener('tt0111161', () => notified++);
      service.request('tt0111161');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 1);
      expect(notified, 1);
      expect(service.scoreFor('tt0111161'), 89);

      // A stable title is never asked for again.
      service.request('tt0111161');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 1);
    });

    test('a fresh persisted answer costs no request', () async {
      SharedPreferences.setMockInitialValues({
        'omdb_ratings_cache_v2': jsonEncode({
          'tt0111161': OmdbCacheEntry(
            score: 89,
            at: DateTime.now().subtract(const Duration(days: 200)),
            released: DateTime(1994, 10, 14),
          ).toJson(),
        }),
      });
      var calls = 0;
      final service = OmdbRatingsService(
        apiKey: 'k',
        clientFactory: () => MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      service.addListener('tt0111161', () {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 0);
      expect(service.scoreFor('tt0111161'), 89);
    });

    test('pauses everything once the daily limit is hit', () async {
      var calls = 0;
      final service = OmdbRatingsService(
        apiKey: 'k',
        clientFactory: () => MockClient((_) async {
          calls++;
          return http.Response(
            jsonEncode({'Response': 'False', 'Error': 'Request limit reached!'}),
            401,
          );
        }),
      );
      service.addListener('tt0000001', () {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      service.addListener('tt0000002', () {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 1);
      expect(service.scoreFor('tt0000001'), isNull);
    });

    test('no key, no traffic', () async {
      var calls = 0;
      final service = OmdbRatingsService(
        apiKey: '',
        clientFactory: () => MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      service.addListener('tt0111161', () {});
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 0);
    });
  });

  group('seasons', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    final now = DateTime(2026, 10, 9);

    test('parses ratings; a stray undated pilot on an old season is settled', () {
      final entry = OmdbRatingsService.parseSeason({
        'Episodes': [
          {'Episode': '0', 'Released': 'N/A', 'imdbRating': 'N/A'},
          {'Episode': '1', 'Released': '2011-04-17', 'imdbRating': '8.9'},
          {'Episode': '2', 'Released': '2011-04-24', 'imdbRating': 'N/A'},
        ],
      }, now);
      expect(entry.ratings, {1: 8.9});
      expect(entry.airing, isFalse);
      expect(
        OmdbRatingsService.seasonTtlFor(entry, now),
        const Duration(days: 365),
      );
    });

    test('an airing season is rechecked within days', () {
      final entry = OmdbRatingsService.parseSeason({
        'Episodes': [
          {'Episode': '1', 'Released': '2026-10-01', 'imdbRating': '8.0'},
          {'Episode': '2', 'Released': '2026-10-15', 'imdbRating': 'N/A'},
        ],
      }, now);
      expect(entry.airing, isTrue);
      expect(
        OmdbRatingsService.seasonTtlFor(entry, now),
        const Duration(days: 2),
      );
    });

    test('a finished season is fetched once and then served from cache', () async {
      var calls = 0;
      final service = OmdbRatingsService(
        apiKey: 'k',
        clientFactory: () => MockClient((request) async {
          calls++;
          expect(request.url.queryParameters['Season'], '1');
          return http.Response(
            jsonEncode({
              'Response': 'True',
              'Episodes': [
                {'Episode': '1', 'Released': '2011-04-17', 'imdbRating': '8.9'},
              ],
            }),
            200,
          );
        }),
      );
      final a = service.seasonRatings('tt0944947', 1);
      final b = service.seasonRatings('tt0944947', 1);
      expect(await a, {1: 8.9});
      expect(await b, {1: 8.9});
      expect(await service.seasonRatings('tt0944947', 1), {1: 8.9});
      expect(calls, 1);
      expect(await service.seasonRatings('tt0944947', 0), isNull);
    });
  });
}
