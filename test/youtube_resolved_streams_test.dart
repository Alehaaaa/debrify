import 'dart:async';

import 'package:debrify/services/youtube_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('shared YouTube resolution', () {
    const stream = YoutubeResolvedStreams(
      playUrl: 'https://example.com/video.mp4',
    );
    setUp(YoutubeService.resetResolutionForTesting);
    tearDown(YoutubeService.resetResolutionForTesting);

    test('concurrent callers and warm cache share one extraction', () async {
      final pending =
          Completer<({YoutubeResolvedStreams streams, String client})?>();
      var calls = 0;
      YoutubeService.streamResolverOverride =
          (id, height, captions, vp9, metadata, muxed, preferred) {
            calls++;
            return pending.future;
          };
      final first = YoutubeService.resolvePreviewStreams(
        'aaaaaaaaaaa',
        maxHeightOverride: 720,
      );
      final second = YoutubeService.resolvePreviewStreams(
        'aaaaaaaaaaa',
        maxHeightOverride: 720,
      );
      pending.complete((streams: stream, client: 'androidSdkless'));
      expect(await first, same(stream));
      expect(await second, same(stream));
      expect(
        await YoutubeService.resolvePreviewStreams(
          'aaaaaaaaaaa',
          maxHeightOverride: 720,
        ),
        same(stream),
      );
      expect(calls, 1);
    });

    test(
      'preview skips metadata; full playback keeps a separate cache',
      () async {
        final metadataRequests = <bool>[];
        final preferredClients = <String?>[];
        YoutubeService.streamResolverOverride =
            (id, height, captions, vp9, metadata, muxed, preferred) async {
              metadataRequests.add(metadata);
              preferredClients.add(preferred);
              return (streams: stream, client: 'androidSdkless');
            };
        await YoutubeService.resolvePreviewStreams(
          'aaaaaaaaaaa',
          maxHeightOverride: 720,
        );
        await YoutubeService.resolveStreams(
          'aaaaaaaaaaa',
          maxHeightOverride: 720,
        );
        expect(metadataRequests, [false, true]);
        expect(preferredClients, [null, 'androidSdkless']);
      },
    );

    test(
      'retry discards expired URLs and pending results cannot recache them',
      () async {
        final old =
            Completer<({YoutubeResolvedStreams streams, String client})?>();
        final fresh =
            Completer<({YoutubeResolvedStreams streams, String client})?>();
        var calls = 0;
        YoutubeService.streamResolverOverride =
            (id, height, captions, vp9, metadata, muxed, preferred) {
              calls++;
              return calls == 1 ? old.future : fresh.future;
            };
        final stale = YoutubeService.resolvePreviewStreams(
          'aaaaaaaaaaa',
          maxHeightOverride: 720,
        );
        YoutubeService.invalidateStreams('aaaaaaaaaaa');
        final retry = YoutubeService.resolvePreviewStreams(
          'aaaaaaaaaaa',
          maxHeightOverride: 720,
        );
        old.complete((
          streams: const YoutubeResolvedStreams(
            playUrl: 'https://example.com/stale',
          ),
          client: 'androidVr',
        ));
        await stale;
        // Completing the old request must not delete the new in-flight request.
        final joined = YoutubeService.resolvePreviewStreams(
          'aaaaaaaaaaa',
          maxHeightOverride: 720,
        );
        expect(calls, 2);
        fresh.complete((streams: stream, client: 'androidSdkless'));
        expect(await retry, same(stream));
        expect(await joined, same(stream));
        expect(
          await YoutubeService.resolvePreviewStreams(
            'aaaaaaaaaaa',
            maxHeightOverride: 720,
          ),
          same(stream),
        );
        expect(calls, 2);
      },
    );

    test(
      'trailer playback failure invalidates all cached variants of its URL',
      () async {
        var calls = 0;
        YoutubeService.streamResolverOverride =
            (id, height, captions, vp9, metadata, muxed, preferred) async {
              calls++;
              return (streams: stream, client: 'androidVr');
            };
        await YoutubeService.resolvePreviewStreams(
          'aaaaaaaaaaa',
          maxHeightOverride: 720,
        );
        await YoutubeService.resolveStreams(
          'aaaaaaaaaaa',
          maxHeightOverride: 1080,
        );
        YoutubeService.invalidateStreamUrl(stream.playUrl);
        await YoutubeService.resolvePreviewStreams(
          'aaaaaaaaaaa',
          maxHeightOverride: 720,
        );
        await YoutubeService.resolveStreams(
          'aaaaaaaaaaa',
          maxHeightOverride: 1080,
        );
        expect(calls, 4);
      },
    );

    test('signed URLs expiring within 30 seconds are resolved again', () async {
      var calls = 0;
      YoutubeService.streamResolverOverride =
          (id, height, captions, vp9, metadata, muxed, preferred) async {
            calls++;
            return (
              streams: YoutubeResolvedStreams(
                playUrl: 'https://example.com/video?expire=1',
              ),
              client: 'androidVr',
            );
          };
      await YoutubeService.resolvePreviewStreams(
        'aaaaaaaaaaa',
        maxHeightOverride: 720,
      );
      await YoutubeService.resolvePreviewStreams(
        'aaaaaaaaaaa',
        maxHeightOverride: 720,
      );
      expect(calls, 2);
    });
  });

  group('YoutubeResolvedStreams.muxedPlaybackFallback', () {
    test('returns a download URL known to contain audio', () {
      const streams = YoutubeResolvedStreams(
        playUrl: 'https://example.com/video-only.mp4',
        audioUrl: 'https://example.com/audio.m4a',
        downloadUrl: 'https://example.com/muxed.mp4',
        downloadHasAudio: true,
      );

      expect(streams.muxedPlaybackFallback, 'https://example.com/muxed.mp4');
    });

    test('rejects a video-only download URL as a playback fallback', () {
      const streams = YoutubeResolvedStreams(
        playUrl: 'https://example.com/video-only.mp4',
        audioUrl: 'https://example.com/audio.m4a',
        downloadUrl: 'https://example.com/video-only.mp4',
        downloadHasAudio: false,
      );

      expect(streams.muxedPlaybackFallback, isNull);
    });
  });
}
