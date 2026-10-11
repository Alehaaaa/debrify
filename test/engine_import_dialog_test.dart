import 'dart:async';
import 'dart:io';

import 'package:debrify/screens/settings/engine_import_page.dart';
import 'package:debrify/services/engine/local_engine_storage.dart';
import 'package:debrify/services/engine/remote_engine_manager.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/theme/glass_chrome.dart';
import 'package:debrify/theme/premium_looks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _DeferredEngineStorage extends LocalEngineStorage {
  _DeferredEngineStorage() : super.forDirectory(Directory.systemTemp);

  final pending = Completer<List<ImportedEngineMetadata>>();

  @override
  Future<List<ImportedEngineMetadata>> getImportedEngines() => pending.future;
}

class _TrackingRemoteEngines extends RemoteEngineManager {
  int requests = 0;

  @override
  Future<List<RemoteEngineInfo>> fetchAvailableEngines() async {
    requests++;
    return [];
  }
}

void main() {
  testWidgets('engine import confirmations reopen with selected appearance', (
    tester,
  ) async {
    Widget host(AppTheme app) => MaterialApp(
      home: AppThemeScope(
        theme: app,
        child: Scaffold(
          body: Builder(
            builder: (pageContext) => Center(
              child: TextButton(
                onPressed: () => showDialog<void>(
                  context: pageContext,
                  builder: (dialogContext) => buildEngineImportDialog(
                    pageContext,
                    title: const Text('Delete Engine'),
                    content: const Text('Remove this engine?'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dialogContext),
                        child: const Text('Cancel'),
                      ),
                    ],
                  ),
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    );

    final frosted = PremiumLooks.glass.build();
    await tester.pumpWidget(host(frosted));
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
      expect(dialog.backgroundColor, GlassChrome.fill(frosted, raised: true));
      expect(
        (dialog.shape! as RoundedRectangleBorder).side.color,
        GlassChrome.edge(frosted),
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
    }

    await tester.pumpWidget(host(AppThemes.legacy));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    final classic = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect(classic.backgroundColor, isNull);
    expect(classic.shape, isNull);
  });

  testWidgets(
    'disposing nested engine import cancels its deferred remote load',
    (tester) async {
      final storage = _DeferredEngineStorage();
      final remote = _TrackingRemoteEngines();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: EngineImportPageContent(
              localStorage: storage,
              remoteManager: remote,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Loading engines...'), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
      storage.pending.complete([]);
      await tester.pump();
      expect(remote.requests, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
