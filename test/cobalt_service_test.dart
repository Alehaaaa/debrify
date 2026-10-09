import 'dart:convert';
import 'package:debrify/services/cobalt_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final fast = Uri.parse('https://fast.example/');
  final slow = Uri.parse('https://slow.example/');
  http.Response healthy({bool protected = false}) => http.Response(
    jsonEncode({
      'cobalt': {
        'services': ['youtube'],
        if (protected) 'turnstileSitekey': 'required',
      },
    }),
    200,
  );
  // Tunnel probes read the stream's first bytes: an MP4 starts with `ftyp`.
  final mp4Head = [0, 0, 0, 24, ...'ftypisom'.codeUnits];
  http.Client Function() mock(
    Future<http.Response> Function(http.Request request) handler,
  ) => () => MockClient(
    (r) async => r.method == 'GET' && r.url.path.endsWith('/tunnel')
        ? http.Response.bytes(mp4Head, 200)
        : handler(r),
  );
  http.Response media(Uri endpoint) => http.Response(
    jsonEncode({'status': 'tunnel', 'url': '${endpoint}tunnel?id=video'}),
    200,
  );

  test(
    'selects lowest measured latency, caches health, requests selected quality',
    () async {
      final requests = <http.Request>[];
      final service = CobaltService(
        instances: [slow, fast],
        clientFactory: mock((r) async {
          requests.add(r);
          if (r.method == 'GET') {
            if (r.url == slow) {
              await Future<void>.delayed(const Duration(milliseconds: 30));
            }
            return healthy();
          }
          expect(r.url, fast);
          final body = jsonDecode(r.body) as Map;
          expect(body['videoQuality'], '1080');
          expect(body['youtubeVideoCodec'], 'h264');
          expect(body['localProcessing'], 'disabled');
          expect(r.followRedirects, false);
          expect(r.headers.containsKey('Authorization'), false);
          return media(fast);
        }),
      );
      expect(
        (await service.resolve('aaaaaaaaaaa', maxHeight: 2160))?.instance,
        fast,
      );
      await service.resolve('bbbbbbbbbbb', maxHeight: 2160);
      expect(requests.where((r) => r.method == 'GET'), hasLength(2));
      expect(requests.where((r) => r.method == 'POST'), hasLength(2));
    },
  );
  test('protected instances receive no video or challenge requests', () async {
    final service = CobaltService(
      instances: [fast],
      clientFactory: mock((r) async {
        expect(r.method, 'GET');
        return healthy(protected: true);
      }),
    );
    expect(await service.resolve('aaaaaaaaaaa', maxHeight: 1080), isNull);
  });
  test('rate-limited instance is skipped through Retry-After', () async {
    var now = DateTime.utc(2026, 10, 9, 12);
    var posts = 0;
    final service = CobaltService(
      instances: [fast],
      now: () => now,
      clientFactory: mock((r) async {
        if (r.method == 'GET') return healthy();
        posts++;
        return http.Response('{}', 429, headers: {'retry-after': '600'});
      }),
    );
    await service.resolve('aaaaaaaaaaa', maxHeight: 1080);
    now = now.add(const Duration(minutes: 6));
    await service.resolve('bbbbbbbbbbb', maxHeight: 1080);
    expect(posts, 1);
    now = now.add(const Duration(minutes: 5));
    await service.resolve('ccccccccccc', maxHeight: 1080);
    expect(posts, 2);
  });
  test('HTTP-date Retry-After is honored', () async {
    var now = DateTime.utc(2026, 10, 9, 12);
    var posts = 0;
    final service = CobaltService(
      instances: [fast],
      now: () => now,
      clientFactory: mock((r) async {
        if (r.method == 'GET') return healthy();
        posts++;
        return http.Response(
          '{}',
          429,
          headers: {'retry-after': 'Fri, 09 Oct 2026 13:00:00 GMT'},
        );
      }),
    );
    await service.resolve('aaaaaaaaaaa', maxHeight: 1080);
    now = now.add(const Duration(minutes: 59));
    await service.resolve('bbbbbbbbbbb', maxHeight: 1080);
    expect(posts, 1);
  });
  test('format error does not disable instance for other videos', () async {
    var posts = 0;
    final service = CobaltService(
      instances: [fast],
      clientFactory: mock((r) async {
        if (r.method == 'GET') return healthy();
        posts++;
        return posts == 1
            ? http.Response(
                '{"status":"error","error":{"code":"error.api.youtube.no_matching_format"}}',
                400,
              )
            : media(fast);
      }),
    );
    expect(await service.resolve('aaaaaaaaaaa', maxHeight: 2160), isNull);
    expect(await service.resolve('bbbbbbbbbbb', maxHeight: 1080), isNotNull);
  });
  test('authentication denial is not retried or circumvented', () async {
    var posts = 0;
    final service = CobaltService(
      instances: [fast],
      clientFactory: mock((r) async {
        if (r.method == 'GET') return healthy();
        posts++;
        return http.Response('{}', 401);
      }),
    );
    await service.resolve('aaaaaaaaaaa', maxHeight: 1080);
    await service.resolve('bbbbbbbbbbb', maxHeight: 1080);
    expect(posts, 1);
  });
  for (final url in [
    'http://fast.example/tunnel',
    'https://127.0.0.1/private',
    'https://unrelated.example/file',
    'https://user:pass@fast.example/file',
  ]) {
    test('rejects unsafe media URL $url', () async {
      final service = CobaltService(
        instances: [fast],
        clientFactory: mock(
          (r) async => r.method == 'GET'
              ? healthy()
              : http.Response(
                  jsonEncode({'status': 'tunnel', 'url': url}),
                  200,
                ),
        ),
      );
      expect(await service.resolve('aaaaaaaaaaa', maxHeight: 1080), isNull);
    });
  }
  test(
    'expired media is rejected and the next healthy instance is used',
    () async {
      final now = DateTime.utc(2026, 10, 9);
      final posts = <Uri>[];
      final service = CobaltService(
        instances: [fast, slow],
        now: () => now,
        clientFactory: mock((r) async {
          if (r.method == 'GET') {
            if (r.url == slow) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            return healthy();
          }
          posts.add(r.url);
          return r.url == fast
              ? http.Response(
                  jsonEncode({
                    'status': 'tunnel',
                    'url':
                        '${fast}tunnel?exp=${now.millisecondsSinceEpoch - 1}',
                  }),
                  200,
                )
              : media(slow);
        }),
      );
      expect(
        (await service.resolve('aaaaaaaaaaa', maxHeight: 1080))?.instance,
        slow,
      );
      expect(posts, [fast, slow]);
      posts.clear();
      await service.resolve('bbbbbbbbbbb', maxHeight: 1080);
      expect(posts, [slow]);
    },
  );
  test('rate limiting on health checks also honors Retry-After', () async {
    var now = DateTime.utc(2026, 10, 9);
    var requests = 0;
    final service = CobaltService(
      instances: [fast],
      now: () => now,
      clientFactory: mock((r) async {
        requests++;
        expect(r.method, 'GET');
        return http.Response('{}', 429, headers: {'retry-after': '3600'});
      }),
    );
    await service.resolve('aaaaaaaaaaa', maxHeight: 1080);
    now = now.add(const Duration(minutes: 20));
    await service.resolve('bbbbbbbbbbb', maxHeight: 1080);
    expect(requests, 1);
  });
  test('simultaneous playback requests share the health scan', () async {
    var checks = 0;
    final service = CobaltService(
      instances: [fast],
      clientFactory: mock((r) async {
        if (r.method == 'GET') {
          checks++;
          await Future<void>.delayed(const Duration(milliseconds: 10));
          return healthy();
        }
        return media(fast);
      }),
    );
    final results = await Future.wait([
      service.resolve('aaaaaaaaaaa', maxHeight: 1080),
      service.resolve('bbbbbbbbbbb', maxHeight: 1080),
    ]);
    expect(checks, 1);
    expect(results.every((r) => r != null), true);
  });
  test(
    'a YouTube sign-in refusal skips to the next instance without parking it',
    () async {
      final posts = <Uri>[];
      final service = CobaltService(
        instances: [fast, slow],
        clientFactory: mock((r) async {
          if (r.method == 'GET') {
            if (r.url == slow) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            return healthy();
          }
          posts.add(r.url);
          final id = (jsonDecode(r.body) as Map)['url'].toString();
          return r.url == fast && id.endsWith('aaaaaaaaaaa')
              ? http.Response(
                  '{"status":"error","error":{"code":"error.api.youtube.login"}}',
                  400,
                )
              : media(r.url);
        }),
      );
      expect(
        (await service.resolve('aaaaaaaaaaa', maxHeight: 1080))?.instance,
        slow,
      );
      // The refusal was about that video: the fast instance still serves others.
      expect(
        (await service.resolve('bbbbbbbbbbb', maxHeight: 1080))?.instance,
        fast,
      );
      expect(posts, [fast, slow, fast]);
    },
  );
  test('an empty tunnel is never handed to the player', () async {
    final probes = <Uri>[];
    final service = CobaltService(
      instances: [fast, slow],
      clientFactory: () => MockClient((r) async {
        if (r.method == 'GET' && r.url.path.endsWith('/tunnel')) {
          probes.add(r.url);
          // YouTube blocked the instance: 200 with nothing to play.
          return r.url.host == fast.host
              ? http.Response('', 200)
              : http.Response.bytes([0, 0, 0, 24, ...'ftypisom'.codeUnits], 200);
        }
        if (r.method == 'GET') {
          if (r.url == slow) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          return healthy();
        }
        return media(r.url);
      }),
    );
    final result = await service.resolve('aaaaaaaaaaa', maxHeight: 1080);
    expect(result?.instance, slow);
    expect(probes.map((u) => u.host), [fast.host, slow.host]);
  });
  test('a video no instance can serve is not re-requested at once', () async {
    var posts = 0;
    var now = DateTime.utc(2026, 10, 9);
    final service = CobaltService(
      instances: [fast],
      now: () => now,
      clientFactory: mock((r) async {
        if (r.method == 'GET') return healthy();
        posts++;
        return http.Response(
          '{"status":"error","error":{"code":"error.api.youtube.login"}}',
          400,
        );
      }),
    );
    expect(await service.resolve('aaaaaaaaaaa', maxHeight: 1080), isNull);
    expect(await service.resolve('aaaaaaaaaaa', maxHeight: 1080), isNull);
    expect(posts, 1);
    now = now.add(const Duration(minutes: 11));
    await service.resolve('aaaaaaaaaaa', maxHeight: 1080);
    expect(posts, 2);
  });
  test(
    'a refusal while another instance is rate-limited is not remembered',
    () async {
      var now = DateTime.utc(2026, 10, 9);
      var fastPosts = 0;
      final service = CobaltService(
        instances: [fast, slow],
        now: () => now,
        clientFactory: mock((r) async {
          if (r.method == 'GET') return healthy();
          if (r.url == slow) {
            return http.Response('{}', 429, headers: {'retry-after': '40'});
          }
          fastPosts++;
          return http.Response(
            '{"status":"error","error":{"code":"error.api.youtube.login"}}',
            400,
          );
        }),
      );
      expect(await service.resolve('aaaaaaaaaaa', maxHeight: 1080), isNull);
      // The slow instance never answered about this video.
      expect(service.knowsUnservable('aaaaaaaaaaa'), false);
      now = now.add(const Duration(seconds: 41));
      await service.resolve('aaaaaaaaaaa', maxHeight: 1080);
      expect(fastPosts, 2);
    },
  );
  test('invalid video IDs never make network requests', () async {
    final service = CobaltService(
      instances: [fast],
      clientFactory: () => throw StateError('network'),
    );
    expect(await service.resolve('invalid', maxHeight: 1080), isNull);
  });
}
