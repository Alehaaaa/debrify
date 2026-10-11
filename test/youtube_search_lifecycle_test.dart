import 'dart:async';
import 'dart:convert';

import 'package:debrify/services/youtube_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response searchPage(String title, String? next) => http.Response(
  jsonEncode({
    'contents': [
      {
        'videoRenderer': {
          'videoId': 'abcdefghijk',
          'title': {'simpleText': title},
        },
      },
      if (next != null)
        {
          'continuationItemRenderer': {
            'continuationEndpoint': {
              'continuationCommand': {'token': next},
            },
          },
        },
    ],
  }),
  200,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'an older YouTube search cannot replace the latest pagination cursor',
    () async {
      final requests = <String, Completer<http.Response>>{};
      await http.runWithClient(
        () async {
          final oldSearch = YoutubeService.search('old');
          final newSearch = YoutubeService.search('new');
          await Future<void>.delayed(Duration.zero);

          requests['new']!.complete(searchPage('new', 'new-next'));
          expect((await newSearch).videos.single.title, 'new');
          requests['old']!.complete(searchPage('old', 'old-next'));
          await oldSearch;

          final next = YoutubeService.searchMore();
          await Future<void>.delayed(Duration.zero);
          expect(requests.containsKey('new-next'), isTrue);
          requests['new-next']!.complete(searchPage('new page', null));
          expect((await next).videos.single.title, 'new page');
        },
        () => MockClient((request) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final key = (body['query'] ?? body['continuation']).toString();
          return (requests[key] = Completer<http.Response>()).future;
        }),
      );
    },
  );

  test(
    'a stale YouTube continuation cannot publish after a fresh search',
    () async {
      final requests = <String, Completer<http.Response>>{};
      await http.runWithClient(
        () async {
          final first = YoutubeService.search('first');
          await Future<void>.delayed(Duration.zero);
          requests['first']!.complete(searchPage('first', 'page-two'));
          await first;

          final oldPage = YoutubeService.searchMore();
          final replacement = YoutubeService.search('replacement');
          await Future<void>.delayed(Duration.zero);
          requests['replacement']!.complete(
            searchPage('replacement', 'replacement-next'),
          );
          expect((await replacement).videos.single.title, 'replacement');
          requests['page-two']!.complete(searchPage('old page', 'old-next'));
          expect((await oldPage).videos, isEmpty);

          final next = YoutubeService.searchMore();
          await Future<void>.delayed(Duration.zero);
          expect(requests.containsKey('replacement-next'), isTrue);
          requests['replacement-next']!.complete(
            searchPage('correct page', null),
          );
          expect((await next).videos.single.title, 'correct page');
        },
        () => MockClient((request) {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final key = (body['query'] ?? body['continuation']).toString();
          return (requests[key] = Completer<http.Response>()).future;
        }),
      );
    },
  );
}
