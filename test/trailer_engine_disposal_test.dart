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
}
