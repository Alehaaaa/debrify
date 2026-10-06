import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:debrify/widgets/hero_trailer_backdrop.dart';
import 'package:debrify/screens/reels_screen.dart';
import 'package:debrify/services/youtube_service.dart';
import 'package:debrify/models/stremio_addon.dart';
import 'package:debrify/widgets/trailer_engine.dart';

void main() {
  testWidgets(
    'reel keeps the same poster from resolving through first video frame',
    (tester) async {
      final engine = _TextureFirstFrameEngine();
      final item = StremioMeta(id: 'tt1234', type: 'movie', name: 'Scene');
      Widget host(YoutubeResolvedStreams? streams) => MaterialApp(
        home: ReelVideoSurface(
          playback: ReelPlayback(
            item: item,
            streams: streams,
            active: true,
            volume: 100,
          ),
          onPlaybackFailed: () {},
          engineFactory: () async => engine,
          poster: const ColoredBox(
            key: ValueKey('reel-poster'),
            color: Colors.blue,
          ),
        ),
      );
      await tester.pumpWidget(host(null));
      final posterElement = tester.element(
        find.byKey(const ValueKey('reel-poster')),
      );
      await tester.pumpWidget(
        host(
          const YoutubeResolvedStreams(
            playUrl: 'https://example.invalid/hd.mp4',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(
        tester.element(find.byKey(const ValueKey('reel-poster'))),
        same(posterElement),
      );
      final videoOpacity = find.descendant(
        of: find.byType(HeroTrailerBackdrop),
        matching: find.byType(AnimatedOpacity),
      );
      expect(tester.widget<AnimatedOpacity>(videoOpacity).opacity, 0);
      engine._firstFrame.complete();
      await tester.pump();
      await tester.pump();
      expect(tester.widget<AnimatedOpacity>(videoOpacity).opacity, 1);
      expect(
        tester.element(find.byKey(const ValueKey('reel-poster'))),
        same(posterElement),
      );
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets(
    'high-resolution reel hands the decoder to the next visible page',
    (tester) async {
      final engines = <_PendingFirstFrameEngine>[];
      Widget host(int page) => MaterialApp(
        home: Stack(
          children: [
            for (var i = 0; i < 2; i++)
              HeroTrailerBackdrop(
                key: ValueKey(i),
                imageUrl: null,
                videoUrl: 'https://example.invalid/video-$i.mp4',
                audioUrl: 'https://example.invalid/audio-$i.m4a',
                platformViewOverride: false,
                enabled: page == i,
                suspended: page != i,
                highResolutionVideo: true,
                decorative: false,
                startDelay: Duration.zero,
                engineFactory: () async {
                  final engine = _PendingFirstFrameEngine();
                  engines.add(engine);
                  return engine;
                },
              ),
          ],
        ),
      );
      await tester.pumpWidget(host(0));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(engines, hasLength(1));
      expect(engines.first.openedAudio, 'https://example.invalid/audio-0.m4a');
      await tester.pumpWidget(host(1));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(engines.first.disposed, isTrue);
      expect(engines, hasLength(2));
      expect(engines.last.openedUrl, 'https://example.invalid/video-1.mp4');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );

  testWidgets('iOS opens the muxed URL instead of rejecting it as stale', (
    tester,
  ) async {
    final engines = <_PendingFirstFrameEngine>[];
    Widget host(String muxed) => MaterialApp(
      home: HeroTrailerBackdrop(
        imageUrl: null,
        videoUrl: 'https://example.invalid/video-only.mp4',
        audioUrl: 'https://example.invalid/audio.m4a',
        muxedVideoUrl: muxed,
        platformViewOverride: true,
        enabled: true,
        startDelay: Duration.zero,
        engineFactory: () async {
          final engine = _PendingFirstFrameEngine();
          engines.add(engine);
          return engine;
        },
      ),
    );
    await tester.pumpWidget(host('https://example.invalid/muxed.mp4'));
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(engines.single.openedUrl, 'https://example.invalid/muxed.mp4');
    expect(engines.single.openedAudio, isNull);
    expect(engines.single.disposed, isFalse);
    await tester.pumpWidget(host('https://example.invalid/new-muxed.mp4'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(engines.first.disposed, isTrue);
    expect(engines.last.openedUrl, 'https://example.invalid/new-muxed.mp4');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'next iOS reel prepares while current plays and resumes without reopening',
    (tester) async {
      final current = _PendingFirstFrameEngine();
      final next = _PendingFirstFrameEngine();
      Widget host(bool suspended) => MaterialApp(
        home: Stack(
          children: [
            HeroTrailerBackdrop(
              imageUrl: null,
              videoUrl: 'https://example.invalid/current-video.mp4',
              muxedVideoUrl: 'https://example.invalid/current.mp4',
              platformViewOverride: true,
              prewarm: true,
              enabled: true,
              startDelay: Duration.zero,
              engineFactory: () async => current,
            ),
            HeroTrailerBackdrop(
              imageUrl: null,
              videoUrl: 'https://example.invalid/next-video.mp4',
              muxedVideoUrl: 'https://example.invalid/next.mp4',
              platformViewOverride: true,
              prewarm: true,
              enabled: true,
              suspended: suspended,
              startDelay: Duration.zero,
              engineFactory: () async => next,
            ),
          ],
        ),
      );
      await tester.pumpWidget(host(true));
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(current.opened, isTrue);
      expect(next.opened, isTrue);
      expect(next.playCalls, 0);
      expect(next.pauseCalls, greaterThan(0));
      await tester.pumpWidget(host(false));
      await tester.pump();
      expect(next.playCalls, 1);
      expect(next.openCalls, 1);
      expect(next.disposed, isFalse);
      await tester.pumpWidget(const SizedBox());
      expect(current.disposed, isTrue);
      expect(next.disposed, isTrue);
    },
  );

  testWidgets('finite trailer plays once until a new focus session', (
    tester,
  ) async {
    final engines = <_PendingFirstFrameEngine>[];
    final key = GlobalKey<HeroTrailerBackdropState>();
    Widget host(bool enabled) => MaterialApp(
      home: HeroTrailerBackdrop(
        key: key,
        imageUrl: null,
        videoUrl: 'https://example.invalid/trailer.mp4',
        enabled: enabled,
        startDelay: Duration.zero,
        engineFactory: () async {
          final engine = _PendingFirstFrameEngine();
          engines.add(engine);
          return engine;
        },
      ),
    );
    await tester.pumpWidget(host(true));
    await tester.pump(const Duration(milliseconds: 1));
    final engine = engines.single;
    expect(engine.looped, isFalse);
    engine._firstFrame.complete();
    engine.playing.add(true);
    engine.durations.add(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    engine.positions.add(const Duration(seconds: 30));
    engine.playing.add(false);
    await tester.pumpAndSettle();
    expect(engine.disposed, isTrue);
    await tester.pumpWidget(host(true));
    key.currentState!.didPopNext();
    await tester.pump(const Duration(seconds: 5));
    expect(engines, hasLength(1));
    await tester.pumpWidget(host(false));
    await tester.pumpWidget(host(true));
    await tester.pump(const Duration(milliseconds: 1));
    expect(engines, hasLength(2));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'covering a trailer releases its engine and return recreates it',
    (tester) async {
      final engines = <_PendingFirstFrameEngine>[];
      final key = GlobalKey<HeroTrailerBackdropState>();
      await tester.pumpWidget(
        MaterialApp(
          home: HeroTrailerBackdrop(
            key: key,
            imageUrl: null,
            videoUrl: 'https://example.invalid/trailer.mp4',
            enabled: true,
            startDelay: Duration.zero,
            engineFactory: () async {
              final engine = _PendingFirstFrameEngine();
              engines.add(engine);
              return engine;
            },
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(engines, hasLength(1));
      key.currentState!.didPushNext();
      await tester.pump();
      expect(engines.first.disposed, isTrue);
      key.currentState!.didPopNext();
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pump();
      expect(engines, hasLength(2));
      expect(engines.last.opened, isTrue);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('ambient duration updates do not rebuild the video surface', (
    tester,
  ) async {
    final engine = _PendingFirstFrameEngine();
    await tester.pumpWidget(
      MaterialApp(
        home: HeroTrailerBackdrop(
          imageUrl: null,
          videoUrl: 'https://example.invalid/live.m3u8',
          live: true,
          enabled: true,
          startDelay: Duration.zero,
          engineFactory: () async => engine,
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    engine._firstFrame.complete();
    await tester.pump();
    await tester.pumpAndSettle();
    final builds = engine.buildVideoCalls;
    for (var i = 0; i < 8; i++) {
      engine.durations.add(Duration(seconds: 30 + i * 2));
      await tester.pump(const Duration(seconds: 2));
    }
    expect(engine.buildVideoCalls, builds);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('mounts the render surface before the first frame arrives', (
    tester,
  ) async {
    final engine = _PendingFirstFrameEngine();

    await tester.pumpWidget(
      MaterialApp(
        home: HeroTrailerBackdrop(
          imageUrl: null,
          videoUrl: 'https://example.invalid/trailer.mp4',
          enabled: true,
          startDelay: Duration.zero,
          engineFactory: () async => engine,
        ),
      ),
    );
    // Advance the zero-duration start timer, then render the setState that
    // attaches the engine.
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();

    expect(engine.opened, isTrue);
    expect(engine.firstFrameCompleted, isFalse);
    expect(engine.buildVideoCalls, greaterThan(0));
  });
}

class _PendingFirstFrameEngine implements TrailerEngine {
  final Completer<void> _firstFrame = Completer<void>();
  final durations = StreamController<Duration>.broadcast();
  final playing = StreamController<bool>.broadcast();
  final positions = StreamController<Duration>.broadcast();
  bool? looped;
  bool opened = false;
  int openCalls = 0;
  int pauseCalls = 0;
  int playCalls = 0;
  String? openedUrl;
  String? openedAudio;
  bool disposed = false;
  int buildVideoCalls = 0;

  bool get firstFrameCompleted => _firstFrame.isCompleted;

  @override
  bool get rendersUnderlay => true;

  @override
  Stream<bool> get playingStream => playing.stream;

  @override
  Stream<Duration> get positionStream => positions.stream;

  @override
  Stream<Duration> get durationStream => durations.stream;

  @override
  Stream<void> get errorStream => const Stream<void>.empty();

  @override
  Future<void> get firstFrameRendered => _firstFrame.future;

  @override
  Future<void> open({
    required String videoUrl,
    String? audioUrl,
    required double volume,
    required bool loop,
    Map<String, String>? httpHeaders,
  }) async {
    opened = true;
    openCalls++;
    openedUrl = videoUrl;
    openedAudio = audioUrl;
    looped = loop;
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> play() async {
    playCalls++;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  void detach() {}

  @override
  Future<void> dispose() async {
    disposed = true;
    await durations.close();
    await playing.close();
    await positions.close();
  }

  @override
  Widget buildVideo({required BoxFit fit, bool revealed = true}) {
    buildVideoCalls++;
    return const SizedBox.expand();
  }
}

class _TextureFirstFrameEngine extends _PendingFirstFrameEngine {
  @override
  bool get rendersUnderlay => false;
}
