import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/widgets/trailer_status_chip.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('unconfirmed trailer mute request returns to actual host volume', (
    tester,
  ) async {
    var requests = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: AppThemeScope(
          theme: AppThemes.legacy,
          child: Scaffold(
            body: Stack(
              children: [
                Positioned(
                  top: 24,
                  right: 100,
                  child: TrailerStatusChip(
                    loading: false,
                    playing: true,
                    soundOn: false,
                    onSoundToggle: () => requests++,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('TRAILER'));
    await tester.pump();
    expect(requests, 1);
    expect(
      tester.widget<Tooltip>(find.byType(Tooltip)).message,
      'Mute trailer',
    );

    // The host rejected (or could not perform) the change and never echoed it.
    await tester.pump(const Duration(milliseconds: 700));
    expect(
      tester.widget<Tooltip>(find.byType(Tooltip)).message,
      'Unmute trailer',
    );
  });
}
