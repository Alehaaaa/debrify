import 'dart:async';

import 'package:debrify/widgets/trailer_engine.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Exo disposal waits for an orphaned native creation to be released',
    () async {
      const channel = MethodChannel('com.debrify.app/tv_trailer');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final created = Completer<Map<String, dynamic>>();
      final disposed = Completer<void>();
      final calls = <String>[];
      Future<dynamic> handle(MethodCall call) async {
        calls.add(call.method);
        if (call.method == 'create') return await created.future;
        if (call.method == 'dispose') {
          expect((call.arguments as Map)['id'], 42);
          await disposed.future;
        }
        return null;
      }

      messenger.setMockMethodCallHandler(channel, handle);
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final engine = ExoTrailerEngine();
      final opening = engine.open(
        videoUrl: 'https://example.invalid/clip.mp4',
        volume: 0,
        loop: false,
      );
      final release = engine.dispose();
      expect(identical(release, engine.dispose()), isTrue);
      var finished = false;
      release.then((_) => finished = true);
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);

      created.complete({'textureId': 42});
      await Future<void>.delayed(Duration.zero);
      expect(calls.where((call) => call == 'dispose'), hasLength(1));
      expect(finished, isFalse);
      disposed.complete();
      await opening;
      await release;
      expect(finished, isTrue);
      expect(calls.where((call) => call == 'dispose'), hasLength(1));
    },
  );

  test('Exo honors a pause while its native player is still opening', () async {
    const channel = MethodChannel('com.debrify.app/tv_trailer');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final created = Completer<Map<String, dynamic>>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'create') return created.future;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final engine = ExoTrailerEngine();
    final opening = engine.open(
      videoUrl: 'https://example.invalid/clip.mp4',
      volume: 0,
      loop: false,
    );
    await engine.pause();
    expect(calls, ['create']);
    created.complete({'textureId': 53});
    await opening;
    expect(calls.where((call) => call == 'pause'), hasLength(1));
    expect(calls, isNot(contains('getPosition')));

    await engine.play();
    expect(calls.where((call) => call == 'play'), hasLength(1));
    await engine.dispose();
  });

  test('latest Exo playback intent wins during native creation', () async {
    const channel = MethodChannel('com.debrify.app/tv_trailer');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final created = Completer<Map<String, dynamic>>();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'create') return created.future;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

    final engine = ExoTrailerEngine();
    final opening = engine.open(
      videoUrl: 'https://example.invalid/clip.mp4',
      volume: 0,
      loop: false,
    );
    await engine.pause();
    await engine.play();
    created.complete({'textureId': 54});
    await opening;
    expect(calls, isNot(contains('pause')));
    await engine.dispose();
  });

  test(
    'Exo replays early native frames but ignores callbacks after release',
    () async {
      const channel = MethodChannel('com.debrify.app/tv_trailer');
      const codec = StandardMethodCodec();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final creates = <Completer<Map<String, dynamic>>>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'create') {
          final pending = Completer<Map<String, dynamic>>();
          creates.add(pending);
          return pending.future;
        }
        return null;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      Future<void> nativeEvent(String method) async {
        final reply = Completer<void>();
        messenger.handlePlatformMessage(
          channel.name,
          codec.encodeMethodCall(MethodCall(method, const {'id': 63})),
          (_) => reply.complete(),
        );
        await reply.future;
      }

      final first = ExoTrailerEngine();
      final firstOpening = first.open(
        videoUrl: 'https://example.invalid/one.mp4',
        volume: 0,
        loop: false,
      );
      await nativeEvent('firstFrame'); // First-frame callback beats create().
      for (var i = 0; i < 20; i++) {
        await nativeEvent('playing'); // Must not evict the sole first frame.
      }
      creates.first.complete({'textureId': 63});
      await firstOpening;
      await first.firstFrameRendered;
      await first.dispose();

      await nativeEvent('firstFrame'); // Released decoder must not queue.
      final second = ExoTrailerEngine();
      final secondOpening = second.open(
        videoUrl: 'https://example.invalid/two.mp4',
        volume: 0,
        loop: false,
      );
      creates.last.complete({'textureId': 63});
      await secondOpening;
      var framed = false;
      second.firstFrameRendered.then((_) => framed = true);
      await Future<void>.delayed(Duration.zero);
      expect(framed, isFalse);
      await nativeEvent('firstFrame');
      await second.firstFrameRendered;
      await second.dispose();
    },
  );
}
