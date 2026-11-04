import 'package:debrify/screens/video_player/utils/gesture_helpers.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const size = Size(900, 400);

  test('outer thirds seek, the middle third plays / pauses', () {
    expect(
      doubleTapZoneFor(const Offset(100, 200), size),
      DoubleTapZone.seekBack,
    );
    expect(
      doubleTapZoneFor(const Offset(450, 200), size),
      DoubleTapZone.playPause,
    );
    expect(
      doubleTapZoneFor(const Offset(350, 50), size),
      DoubleTapZone.playPause,
    );
    expect(
      doubleTapZoneFor(const Offset(800, 200), size),
      DoubleTapZone.seekForward,
    );
  });
}
