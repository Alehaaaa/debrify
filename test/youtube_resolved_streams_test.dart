import 'dart:async';
import 'package:debrify/services/cobalt_service.dart';
import 'package:debrify/services/storage_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:debrify/services/youtube_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  group('shared YouTube resolution', () {
    const stream = YoutubeResolvedStreams(
      playUrl: 'https://example.com/video.mp4',
    );
    setUp(YoutubeService.resetResolutionForTesting);
    tearDown(YoutubeService.resetResolutionForTesting);

    test('changed quality preference does not reuse the old default', () async {
      SharedPreferences.setMockInitialValues({});
      final requested = <int>[];
      YoutubeService.streamResolverOverride =
          (id, height, cc, vp9, meta, muxed, client) async {
            requested.add(height);
            return (streams: stream, client: 'androidVr');
          };
      await StorageService.setYoutubeMaxHeight(720);
      await YoutubeService.resolveStreams('aaaaaaaaaaa');
      await StorageService.setYoutubeMaxHeight(2160);
      await YoutubeService.resolveStreams('aaaaaaaaaaa');
      expect(requested, [720, 1080]);
    });
    test('expiring relay URLs are never returned from warm cache', () async {
      var calls = 0;
      YoutubeService.streamResolverOverride =
          (id, height, cc, vp9, meta, muxed, client) async {
            calls++;
            return (
              streams: YoutubeResolvedStreams(
                playUrl:
                    'https://relay.example/tunnel?exp=${DateTime.now().millisecondsSinceEpoch + 10000}',
              ),
              client: 'cobalt',
            );
          };
      await YoutubeService.resolveStreams(
        'aaaaaaaaaaa',
        maxHeightOverride: 1080,
      );
      await YoutubeService.resolveStreams(
        'aaaaaaaaaaa',
        maxHeightOverride: 1080,
      );
      expect(calls, 2);
    });
    test('explicit high-resolution overrides are capped at 1080p', () async {
      final requested = <int>[];
      YoutubeService.streamResolverOverride =
          (id, height, cc, vp9, meta, muxed, client) async {
            requested.add(height);
            return (streams: stream, client: 'androidVr');
          };
      await YoutubeService.resolvePreviewStreams(
        'aaaaaaaaaaa',
        maxHeightOverride: 2160,
      );
      expect(requested, [1080]);
    });
    test(
      'trailers and reels both resolve through Cobalt without direct extraction',
      () async {
        final heights = <int>[];
        YoutubeService.cobaltResolverOverride = (id, height) async {
          heights.add(height);
          return CobaltMedia(
            'https://relay.example/tunnel?id=$id',
            Uri.parse('https://relay.example/'),
          );
        };
        YoutubeService.streamResolverOverride =
            (id, height, cc, vp9, meta, muxed, client) async {
              fail('Cobalt already supplied playable preview streams');
            };
        final trailer = await YoutubeService.resolvePreviewStreams(
          'aaaaaaaaaaa',
          maxHeightOverride: 720,
        );
        // iOS reels ask for a single muxed URL: they relay too.
        final reel = await YoutubeService.resolvePreviewStreams(
          'bbbbbbbbbbb',
          maxHeightOverride: 1080,
          preferMuxed: true,
        );
        // The detail page's Trailer button: no metadata, full player.
        final button = await YoutubeService.resolveStreams(
          'ccccccccccc',
          maxHeightOverride: 1080,
          includeMetadata: false,
        );
        expect(heights, [720, 1080, 1080]);
        for (final streams in [trailer!, reel!, button!]) {
          expect(streams.hasPlayable, true);
          expect(streams.isRelay, true);
          expect(streams.audioUrl, isNull);
          // Never offered to AVFoundation, which needs byte ranges: iOS
          // backdrops play the tunnel through media_kit instead.
          expect(streams.muxedPlaybackFallback, isNull);
          expect(streams.validUntil, isNotNull);
          expect(streams.needsRefresh, false);
        }
      },
    );
    test('relay lifetime follows the tunnel expiry Cobalt reports', () async {
      final expiresAt = DateTime.now().add(const Duration(seconds: 90));
      YoutubeService.cobaltResolverOverride = (id, height) async => CobaltMedia(
        'https://relay.example/tunnel?id=$id',
        Uri.parse('https://relay.example/'),
        expiresAt: expiresAt,
      );
      final streams = await YoutubeService.resolvePreviewStreams(
        'aaaaaaaaaaa',
        maxHeightOverride: 720,
      );
      expect(streams!.validUntil, expiresAt);
    });
    test(
      'full playback extracts directly and relays only when that fails',
      () async {
        final relayed = <String>[];
        YoutubeService.cobaltResolverOverride = (id, height) async {
          relayed.add(id);
          return CobaltMedia(
            'https://relay.example/tunnel?id=$id',
            Uri.parse('https://relay.example/'),
          );
        };
        YoutubeService.streamResolverOverride =
            (id, height, cc, vp9, meta, muxed, client) async =>
                id == 'aaaaaaaaaaa' ? (streams: stream, client: 'androidVr') : null;
        expect(
          await YoutubeService.resolveStreams(
            'aaaaaaaaaaa',
            maxHeightOverride: 1080,
            withCaptions: true,
          ),
          same(stream),
        );
        expect(relayed, isEmpty);
        // YouTube bot-checked this device: the relay still plays it.
        final blocked = await YoutubeService.resolveStreams(
          'bbbbbbbbbbb',
          maxHeightOverride: 1080,
          withCaptions: true,
        );
        expect(blocked!.isRelay, true);
        expect(relayed, ['bbbbbbbbbbb']);
      },
    );
    test('allowRelay: false never relays, even when direct fails', () async {
      YoutubeService.cobaltResolverOverride = (_, _) async =>
          fail('This consumer needs byte ranges');
      YoutubeService.streamResolverOverride =
          (id, height, cc, vp9, meta, muxed, client) async => null;
      expect(
        await YoutubeService.resolvePreviewStreams(
          'aaaaaaaaaaa',
          maxHeightOverride: 1080,
          allowRelay: false,
        ),
        isNull,
      );
      expect(
        await YoutubeService.resolveStreams(
          'aaaaaaaaaaa',
          maxHeightOverride: 1080,
          allowRelay: false,
        ),
        isNull,
      );
    });
    test('a cached relay is never served to a non-relay consumer', () async {
      YoutubeService.cobaltResolverOverride = (id, height) async => CobaltMedia(
        'https://relay.example/tunnel?id=$id',
        Uri.parse('https://relay.example/'),
      );
      YoutubeService.streamResolverOverride =
          (id, height, cc, vp9, meta, muxed, client) async =>
              (streams: stream, client: 'androidVr');
      final relayed = await YoutubeService.resolvePreviewStreams(
        'aaaaaaaaaaa',
        maxHeightOverride: 720,
      );
      final direct = await YoutubeService.resolvePreviewStreams(
        'aaaaaaaaaaa',
        maxHeightOverride: 720,
        allowRelay: false,
      );
      expect(relayed!.isRelay, true);
      expect(direct, same(stream));
    });
    test(
      'a relay that fails in the player is resolved directly next time',
      () async {
        var relayCalls = 0;
        YoutubeService.cobaltResolverOverride = (id, height) async {
          relayCalls++;
          return CobaltMedia(
            'https://relay.example/tunnel?id=$id&n=$relayCalls',
            Uri.parse('https://relay.example/'),
          );
        };
        YoutubeService.streamResolverOverride =
            (id, height, cc, vp9, meta, muxed, client) async =>
                (streams: stream, client: 'androidVr');
        final relayed = await YoutubeService.resolvePreviewStreams(
          'aaaaaaaaaaa',
          maxHeightOverride: 720,
        );
        // Backdrops report failures by URL, even after the entry expired.
        YoutubeService.invalidateStreamUrl(relayed!.playUrl);
        expect(
          await YoutubeService.resolvePreviewStreams(
            'aaaaaaaaaaa',
            maxHeightOverride: 720,
          ),
          same(stream),
        );
        // Other videos still relay.
        expect(
          (await YoutubeService.resolvePreviewStreams(
            'bbbbbbbbbbb',
            maxHeightOverride: 720,
          ))!.isRelay,
          true,
        );
        YoutubeService.markRelayFailed('bbbbbbbbbbb');
        expect(
          await YoutubeService.resolvePreviewStreams(
            'bbbbbbbbbbb',
            maxHeightOverride: 720,
          ),
          same(stream),
        );
        expect(relayCalls, 2);
      },
    );
    test('a fallback while Cobalt is unreachable is reused, not re-relayed per request', () async {
      var relayCalls = 0;
      YoutubeService.cobaltResolverOverride = (_, _) async {
        relayCalls++;
        throw StateError('instance timed out');
      };
      YoutubeService.streamResolverOverride =
          (id, height, cc, vp9, meta, muxed, client) async =>
              (streams: stream, client: 'androidVr');
      await YoutubeService.resolvePreviewStreams(
        'aaaaaaaaaaa',
        maxHeightOverride: 720,
      );
      // Still cached for the next minute (no repeated relay hammering)...
      await YoutubeService.resolvePreviewStreams(
        'aaaaaaaaaaa',
        maxHeightOverride: 720,
      );
      expect(relayCalls, 1);
    });
    test('a throwing relay falls back to direct extraction', () async {
      YoutubeService.cobaltResolverOverride = (_, _) async =>
          throw StateError('instance down');
      YoutubeService.streamResolverOverride =
          (id, height, cc, vp9, meta, muxed, client) async =>
              (streams: stream, client: 'androidVr');
      expect(
        await YoutubeService.resolvePreviewStreams(
          'aaaaaaaaaaa',
          maxHeightOverride: 720,
        ),
        same(stream),
      );
    });
    test('unavailable Cobalt falls back to the low-res muxed stream', () async {
      YoutubeService.cobaltResolverOverride = (_, _) async => null;
      YoutubeService.streamResolverOverride =
          (id, height, cc, vp9, meta, muxed, client) async {
            expect(meta, false);
            // One audio+video file, not the adaptive HD pair.
            expect(muxed, true);
            return (streams: stream, client: 'androidVr');
          };
      expect(
        await YoutubeService.resolvePreviewStreams(
          'aaaaaaaaaaa',
          maxHeightOverride: 1080,
        ),
        same(stream),
      );
    });
    test('a prefetched relay is refreshed when its lifetime expires', () {
      expect(
        YoutubeResolvedStreams(
          playUrl: 'https://relay.example/tunnel',
          validUntil: DateTime.now().subtract(const Duration(seconds: 1)),
        ).needsRefresh,
        true,
      );
      expect(
        const YoutubeResolvedStreams(
          playUrl: 'https://relay.example/tunnel?exp=1',
        ).needsRefresh,
        true,
      );
      expect(stream.needsRefresh, false);
    });
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
    test('reports the selected adaptive stream height', () {
      const streams = YoutubeResolvedStreams(
        playUrl: 'https://example.com/720.mp4',
        qualities: [
          YoutubeQuality(height: 720, videoUrl: 'https://example.com/720.mp4'),
        ],
      );

      expect(streams.playbackHeight, 720);
    });

    test('reports the selected muxed stream height', () {
      const streams = YoutubeResolvedStreams(
        playUrl: 'https://example.com/360.mp4',
        downloadUrl: 'https://example.com/360.mp4',
        downloadHeight: 360,
      );

      expect(streams.playbackHeight, 360);
    });

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
