import 'package:background_downloader/background_downloader.dart';
import 'package:debrify/models/downloaded_media.dart';
import 'package:debrify/screens/downloads_screen.dart';
import 'package:debrify/services/downloaded_media_service.dart';
import 'package:flutter/material.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/widgets/see_all/see_all_poster_grid.dart';
import 'package:debrify/widgets/catalog_item_tile.dart';
import 'package:debrify/widgets/detail/detail_identity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('library reuses Discover grid and includes active downloads', (
    tester,
  ) async {
    final active = LocalDownload(
      TaskRecord(
        DownloadTask(
          taskId: 'active',
          url: 'https://example.com/video',
          filename: 'Movie.mp4',
        ),
        TaskStatus.running,
        .4,
        1024,
      ),
      const DownloadedMedia(
        id: 'tt123',
        title: 'Downloading Movie',
        type: 'movie',
      ),
      '',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: AppThemeScope(
          theme: AppThemes.legacy,
          child: Scaffold(
            body: DownloadsScreen(loadDownloads: () async => [active]),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SeeAllPosterGrid), findsOneWidget);
    final tile = tester.widget<CatalogItemTile>(find.byType(CatalogItemTile));
    // Progress rides the poster's sweep, not the title.
    expect(tile.item.name, 'Downloading Movie');
    expect(tile.progress, isNull);
    expect(tile.downloadProgress, .4);
    expect(tile.downloadStatus, isNull);
    expect(find.text('40%'), findsOneWidget);
    await tester.tap(find.byType(CatalogItemTile));
    await tester.pumpAndSettle();
    expect(find.text('Downloading'), findsOneWidget);
    expect(find.text('DOWNLOAD IN PROGRESS'), findsOneWidget);
    // Nothing finished yet, so there is nothing to play.
    expect(find.byType(DetailPrimaryButton), findsNothing);
  });

  test('only catalog titles with a finished file open the Home detail page', () {
    LocalDownload item(String id, TaskStatus status) => LocalDownload(
      TaskRecord(
        DownloadTask(taskId: '$id-$status', url: 'https://e.com/v', filename: 'f.mkv'),
        status,
        status == TaskStatus.complete ? 1 : .5,
        1,
      ),
      DownloadedMedia(id: id, title: 'T', type: 'movie'),
      status == TaskStatus.complete ? '/tmp/f.mkv' : '',
    );
    expect(opensHomeDetail([item('tt1', TaskStatus.complete)]), isTrue);
    expect(opensHomeDetail([item('tt1', TaskStatus.running)]), isFalse);
    expect(
      opensHomeDetail([item('download-file:x', TaskStatus.complete)]),
      isFalse,
    );
  });

  for (final size in [const Size(390, 844), const Size(1440, 900)]) {
    testWidgets('download details show only available episodes at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final items = [
        for (final episode in [4, 2])
          LocalDownload(
            TaskRecord(
              DownloadTask(
                taskId: 'download-$episode',
                url: 'https://example.com/video',
                filename: 'Show.S02E0$episode.mkv',
              ),
              TaskStatus.complete,
              1,
              1024,
            ),
            DownloadedMedia(
              id: 'tt1234567',
              title: 'An Example Show With a Long Title',
              type: 'series',
              season: 2,
              episode: episode,
            ),
            '/tmp/not-a-real-download-$episode.mkv',
          ),
      ];
      await tester.pumpWidget(
        MaterialApp(home: DownloadedTitleScreen(items: items)),
      );
      await tester.pump();
      expect(find.text('2 downloaded episodes'), findsOneWidget);
      expect(find.text('S02 · E02'), findsOneWidget);
      expect(find.text('S02 · E04'), findsOneWidget);
      expect(find.text('S02 · E03'), findsNothing);
      expect(
        tester.getTopLeft(find.text('S02 · E02')).dy,
        lessThan(tester.getTopLeft(find.text('S02 · E04')).dy),
      );
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.byTooltip('Remove download').first);
      await tester.tap(find.byTooltip('Remove download').first);
      await tester.pumpAndSettle();
      expect(find.text('Delete download?'), findsOneWidget);
      await tester.tap(find.text('Keep'));
      await tester.pumpAndSettle();
      expect(find.text('S02 · E02'), findsOneWidget);
    });
  }

  testWidgets('failed downloads offer Retry and Delete', (tester) async {
    final failed = LocalDownload(
      TaskRecord(
        DownloadTask(
          taskId: 'failed',
          url: 'https://example.com/video',
          filename: 'Movie.mkv',
        ),
        TaskStatus.failed,
        .2,
        1024,
      ),
      const DownloadedMedia(id: 'tt9', title: 'Broken Movie', type: 'movie'),
      '',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: DownloadedTitleScreen(
          items: [failed],
          detailsLoader: (_) async =>
              (meta: null, videos: const <Map<String, dynamic>>[]),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('DOWNLOAD FAILED'), findsOneWidget);
    expect(find.byTooltip('Retry download'), findsOneWidget);
    expect(find.byTooltip('Remove download'), findsOneWidget);
    // The page can refile the download under the right title.
    expect(find.byTooltip('Fix match'), findsOneWidget);
    await tester.tap(find.byTooltip('Remove download'));
    await tester.pumpAndSettle();
    expect(find.text('Delete download?'), findsOneWidget);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(find.text('Broken Movie'), findsWidgets);
  });
}
