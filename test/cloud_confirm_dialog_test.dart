import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/theme/glass_chrome.dart';
import 'package:debrify/theme/premium_looks.dart';
import 'package:debrify/widgets/cloud/cloud_confirm_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final frosted in [true, false]) {
    testWidgets(
      'Cloud delete confirmation reopens on ${frosted ? 'Glass' : 'Classic'}',
      (tester) async {
        final app = frosted ? PremiumLooks.glass.build() : AppThemes.legacy;
        await tester.binding.setSurfaceSize(const Size(340, 680));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        bool? choice;
        await tester.pumpWidget(
          MaterialApp(
            home: AppThemeScope(
              theme: app,
              child: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () async {
                      choice = await showDialog<bool>(
                        context: context,
                        builder: (_) => const CloudConfirmDialog(
                          title: 'Delete download',
                          message: 'Delete the downloaded item?',
                          confirmLabel: 'Delete',
                        ),
                      );
                    },
                    child: const Text('Manage'),
                  ),
                ),
              ),
            ),
          ),
        );

        for (var attempt = 0; attempt < 2; attempt++) {
          await tester.tap(find.text('Manage'));
          await tester.pumpAndSettle();
          final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
          expect(
            dialog.backgroundColor,
            frosted
                ? GlassChrome.fill(app, raised: true)
                : app.cloud.dialogSurface,
          );
          if (frosted) {
            final shape = dialog.shape! as RoundedRectangleBorder;
            expect(shape.side.color, GlassChrome.edge(app));
          }
          await tester.tap(find.text(attempt == 0 ? 'Cancel' : 'Delete'));
          await tester.pumpAndSettle();
          expect(choice, attempt == 1);
          expect(find.byType(AlertDialog), findsNothing);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
