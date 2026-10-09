import 'dart:async';
import 'package:debrify/services/youtube_resolution_queue.dart';
import 'package:debrify/services/youtube_stream_probe.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'bounded extraction has no total-video quota and preserves all results',
    () async {
      final queue = YoutubeResolutionQueue();
      var active = 0, peak = 0;
      final results = await Future.wait(
        List.generate(
          150,
          (id) => queue.run(() async {
            active++;
            if (active > peak) peak = active;
            await Future<void>.delayed(Duration.zero);
            active--;
            return id;
          }),
        ),
      );
      expect(peak, 2);
      expect(results, List.generate(150, (i) => i));
    },
  );
  test('foreground gets the next slot and failures release capacity', () async {
    final queue = YoutubeResolutionQueue(concurrency: 1);
    final pending = Completer<int>();
    final order = <String>[];
    final first = queue.run(() => pending.future);
    final preview = queue.run(() async {
      order.add('preview');
      return 2;
    }, foreground: false);
    final playback = queue.run<int>(() async {
      order.add('playback');
      throw StateError('failed');
    });
    final failure = expectLater(playback, throwsStateError);
    pending.complete(1);
    await first;
    await failure;
    await preview;
    expect(order, ['playback', 'preview']);
  });
  test('CDN validation uses bounded GET rather than rejected HEAD', () async {
    final client = YoutubePlaybackHttpClient(
      MockClient((request) async {
        expect(request.method, 'GET');
        expect(request.headers['Range'], 'bytes=0-0');
        return http.Response('a', 206);
      }),
    );
    expect(
      (await client.head(
        Uri.parse('https://example.googlevideo.com/videoplayback'),
      )).statusCode,
      206,
    );
    client.close();
  });
  test('explicit access rejection remains rejected', () async {
    final client = MockClient((_) async => http.Response('denied', 403));
    expect(
      (await probeYoutubeStream(
        Uri.parse('https://example.googlevideo.com/videoplayback'),
        client: client,
      )).statusCode,
      403,
    );
    client.close();
  });
  test('invalid media URL is rejected before network access', () async {
    await expectLater(
      probeYoutubeStream(Uri.parse('/missing-host')),
      throwsArgumentError,
    );
  });
}
