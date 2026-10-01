import 'package:debrify/screens/video_player/models/hud_state.dart';
import 'package:debrify/screens/video_player/widgets/vertical_hud.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the meter fills along its height, bottom up', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: VerticalHud(
            hud: VerticalHudState(kind: VerticalKind.volume, value: .25),
          ),
        ),
      ),
    );
    final meter = tester.getRect(find.byKey(const ValueKey('vertical-hud-meter')));
    final fill = tester.getRect(find.byKey(const ValueKey('vertical-hud-fill')));
    expect(fill.width, meter.width);
    expect(fill.height, closeTo(meter.height * .25, .01));
    expect(fill.bottom, meter.bottom);
    expect(find.text('25'), findsOneWidget);
  });
}
