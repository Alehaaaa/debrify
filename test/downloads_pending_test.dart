import 'package:debrify/screens/downloads_screen.dart';
import 'package:debrify/services/downloads/pending_title_downloads.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/theme/glass_chrome.dart';
import 'package:debrify/theme/premium_looks.dart';
import 'package:debrify/widgets/catalog_item_tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(PendingTitleDownloads.resetForTesting);
  tearDown(PendingTitleDownloads.resetForTesting);

  testWidgets('download header buttons follow the selected appearance', (
    tester,
  ) async {
    Widget host(AppTheme app) => MaterialApp(
      home: AppThemeScope(
        theme: app,
        child: Scaffold(
          body: DownloadsScreen(loadDownloads: () async => const []),
        ),
      ),
    );
    Color? refreshFill() => tester
        .widget<Material>(
          find
              .ancestor(
                of: find.byIcon(Icons.refresh_rounded),
                matching: find.byType(Material),
              )
              .first,
        )
        .color;

    final frosted = PremiumLooks.glass.build();
    await tester.pumpWidget(host(frosted));
    await tester.pump();
    expect(refreshFill(), GlassChrome.fill(frosted, raised: true));

    await tester.pumpWidget(host(AppThemes.legacy));
    await tester.pump();
    expect(refreshFill(), Colors.white.withValues(alpha: 0.08));
    await tester.pumpWidget(const SizedBox());
  });

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

  testWidgets('pending download actions use frosted chrome after reopening', (
    tester,
  ) async {
    Widget host(AppTheme app) => MaterialApp(
      home: AppThemeScope(
        theme: app,
        child: Scaffold(
          body: DownloadsScreen(loadDownloads: () async => const []),
        ),
      ),
    );
    var canceled = 0;
    PendingTitleDownloads.begin(
      PendingTitleDownload(
        id: 'tt42',
        title: 'Pending Movie',
        type: 'movie',
        phase: PendingDownloadPhase.searching,
        onCancel: () => canceled++,
      ),
    );
    final frosted = PremiumLooks.glass.build();
    await tester.pumpWidget(host(frosted));
    await tester.pump();
    for (var i = 0; i < 2; i++) {
      await tester.tap(find.byType(CatalogItemTile));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 350));
      final sheet = tester.widget<BottomSheet>(find.byType(BottomSheet));
      expect(sheet.backgroundColor, GlassChrome.fill(frosted, raised: true));
      expect(
        (sheet.shape! as RoundedRectangleBorder).side.color,
        GlassChrome.edge(frosted),
      );
      if (i == 0) {
        Navigator.of(tester.element(find.byType(BottomSheet))).pop();
      } else {
        await tester.tap(find.text('Stop download'));
      }
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(BottomSheet), findsNothing);
    }
    expect(canceled, 1);
    await tester.pumpWidget(host(AppThemes.legacy));
    await tester.pump();
    await tester.tap(find.byType(CatalogItemTile));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    final sheetContext = tester.element(find.byType(BottomSheet));
    expect(
      tester.widget<BottomSheet>(find.byType(BottomSheet)).backgroundColor,
      Theme.of(sheetContext).colorScheme.surfaceContainerLow,
    );
    Navigator.of(tester.element(find.byType(BottomSheet))).pop();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpWidget(const SizedBox());
  });
}
