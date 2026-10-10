import 'package:debrify/screens/downloads_screen.dart';
import 'package:debrify/services/downloads/pending_title_downloads.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/widgets/catalog_item_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(PendingTitleDownloads.resetForTesting);
  tearDown(PendingTitleDownloads.resetForTesting);

  testWidgets(
    'an automatic download still finding its source shows as its poster '
    'with the step on top, then hands over',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: AppThemeScope(
            theme: AppThemes.legacy,
            child: Scaffold(
              body: DownloadsScreen(loadDownloads: () async => const []),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('No downloads yet'), findsOneWidget);

      final token = PendingTitleDownloads.begin(
        const PendingTitleDownload(
          id: 'tt42',
          title: 'Pending Movie',
          type: 'movie',
          phase: PendingDownloadPhase.searching,
        ),
      );
      // The sweep circles forever: pump frames rather than settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final tile = tester.widget<CatalogItemTile>(find.byType(CatalogItemTile));
      expect(tile.item.name, 'Pending Movie');
      expect(tile.downloadProgress, lessThan(0));
      expect(tile.downloadStatus, 'Searching sources');
      expect(find.text('Searching sources'), findsOneWidget);
      // No bytes yet, so no percentage.
      expect(find.textContaining('%'), findsNothing);

      PendingTitleDownloads.update(token, 'tt42', PendingDownloadPhase.adding);
      await tester.pump();
      expect(find.text('Adding source'), findsOneWidget);

      PendingTitleDownloads.end(token, 'tt42');
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(CatalogItemTile), findsNothing);

      await tester.pumpWidget(const SizedBox());
    },
  );
}
