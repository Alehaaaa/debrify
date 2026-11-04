import 'package:debrify/services/media_session_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class _Handler implements MediaSessionHandler {
  final calls = <String>[];
  @override
  void play() => calls.add('play');
  @override
  void pause() => calls.add('pause');
  @override
  void next() => calls.add('next');
  @override
  void previous() => calls.add('previous');
  @override
  void seekTo(Duration position) => calls.add('seekTo ${position.inSeconds}');
  @override
  void seekBy(Duration offset) => calls.add('seekBy ${offset.inSeconds}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('debrify/media_session');
  final sent = <MethodCall>[];
  final service = MediaSessionService.instance;

  setUp(() {
    MediaSessionService.debugForceChannel = true;
    sent.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          sent.add(call);
          return null;
        });
  });

  tearDown(() {
    MediaSessionService.debugForceChannel = false;
  });

  test('publishes the title and play state, throttling position ticks', () {
    final owner = Object();
    service.attach(owner, _Handler());
    service.setMetadata(owner, title: 'The Movie', subtitle: null);
    expect(sent.single.method, 'update');
    expect((sent.single.arguments as Map)['title'], 'The Movie');

    service.setPlayback(
      owner,
      playing: true,
      position: Duration.zero,
      duration: const Duration(minutes: 90),
    );
    expect(sent, hasLength(2));
    expect((sent.last.arguments as Map)['playing'], isTrue);
    expect((sent.last.arguments as Map)['durationMs'], 90 * 60 * 1000);

    // Ordinary progress ticks don't reach the OS between intervals…
    service.setPlayback(
      owner,
      playing: true,
      position: const Duration(milliseconds: 500),
      duration: const Duration(minutes: 90),
    );
    expect(sent, hasLength(2));

    // …a pause and a seek do, straight away.
    service.setPlayback(
      owner,
      playing: false,
      position: const Duration(milliseconds: 600),
      duration: const Duration(minutes: 90),
    );
    expect((sent.last.arguments as Map)['playing'], isFalse);
    service.setPlayback(
      owner,
      playing: false,
      position: const Duration(minutes: 30),
      duration: const Duration(minutes: 90),
    );
    expect((sent.last.arguments as Map)['positionMs'], 30 * 60 * 1000);

    service.detach(owner);
    expect(sent.last.method, 'clear');
  });

  test('routes OS commands to the attached player only', () {
    final first = Object();
    final second = Object();
    final firstHandler = _Handler();
    final secondHandler = _Handler();
    service.attach(first, firstHandler);
    service.attach(second, secondHandler);
    // The older player closing must not clear the newer one's controls.
    service.detach(first);
    expect(sent.where((c) => c.method == 'clear'), isEmpty);

    for (final command in <Map<String, Object?>>[
      {'action': 'pause'},
      {'action': 'play'},
      {'action': 'next'},
      {'action': 'previous'},
      {'action': 'seek', 'positionMs': 120000},
      {'action': 'seekBy', 'offsetMs': -10000},
    ]) {
      service.handleCommandForTesting(command);
    }
    expect(firstHandler.calls, isEmpty);
    expect(secondHandler.calls, [
      'pause',
      'play',
      'next',
      'previous',
      'seekTo 120',
      'seekBy -10',
    ]);
    service.detach(second);
  });
}
