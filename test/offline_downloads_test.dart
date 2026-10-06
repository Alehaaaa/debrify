import 'dart:io';
import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';
import 'package:debrify/models/downloaded_media.dart';
import 'package:debrify/models/stremio_addon.dart';
import 'package:debrify/screens/downloads_screen.dart';
import 'package:debrify/screens/merged_series_detail_screen.dart';
import 'package:debrify/services/downloaded_media_service.dart';
import 'package:debrify/services/download_service.dart';
import 'package:debrify/utils/app_storage.dart';
import 'package:flutter/services.dart';
import 'package:debrify/services/offline_title_store.dart';
import 'package:debrify/services/storage_service.dart';
import 'package:debrify/widgets/catalog_item_tile.dart';
import 'package:debrify/widgets/recoverable_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme/golden_harness.dart' show disableRuntimeFonts;

LocalDownload episode(int number) => LocalDownload(
  TaskRecord(
    DownloadTask(
      url: 'https://unused.test/video',
      filename: 'Show.S01E$number.mkv',
    ),
    TaskStatus.complete,
    1,
    1024,
  ),
  DownloadedMedia(
    id: 'tt123',
    title: 'Saved Show',
    type: 'series',
    season: 1,
    episode: number,
  ),
  '/tmp/episode-$number.mkv',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'local records and completed playback do not wait on platform transfer startup',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'local-download-library-',
      );
      AppStorage.debugOverride(support: dir);
      SharedPreferences.setMockInitialValues({});
      var platformCalls = 0;
      for (final channel in [
        'flutter.baseflow.com/permissions/methods',
        'dev.fluttercommunity.plus/connectivity',
        'com.bbflight.background_downloader',
      ]) {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(MethodChannel(channel), (_) async {
              platformCalls++;
              throw StateError('Unavailable offline');
            });
      }
      addTearDown(() async {
        for (final channel in [
          'flutter.baseflow.com/permissions/methods',
          'dev.fluttercommunity.plus/connectivity',
          'com.bbflight.background_downloader',
        ]) {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(MethodChannel(channel), null);
        }
        AppStorage.debugReset();
        await dir.delete(recursive: true);
      });
      final file = await File(
        '${dir.path}/movie.mkv',
      ).writeAsString('local video');
      await File('${dir.path}/downloads_db_v1.json').writeAsString(
        jsonEncode({
          'done': {
            'state': 'complete',
            'destPath': file.path,
            'meta': jsonEncode({
              'media': {'id': 'tt123', 'title': 'Saved Movie', 'type': 'movie'},
            }),
          },
        }),
      );
      await DownloadService.instance.initializeLibrary();
      expect(
        await DownloadService.instance.completedMediaPath(
          imdbId: 'tt123',
          contentType: 'movie',
        ),
        file.path,
      );
      expect(platformCalls, 0);
    },
  );

  test(
    'downloaded episodes remain reachable without any saved catalog',
    () async {
      final seasons = await downloadedSeasons([episode(3), episode(1)]);
      expect(seasons.single.number, 1);
      expect(seasons.single.episodes.map((e) => e.number), [1, 3]);
    },
  );

  test(
    'downloaded episodes use their saved names and stills after restart',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'offline-episode-test-',
      );
      OfflineTitleStore.debugReset();
      OfflineTitleStore.debugDirectory = () async => dir;
      OfflineTitleStore.debugSkipWarm = true;
      addTearDown(() async {
        OfflineTitleStore.debugReset();
        OfflineTitleStore.debugDirectory = null;
        OfflineTitleStore.debugSkipWarm = false;
        await dir.delete(recursive: true);
      });
      final store = OfflineTitleStore.instance;
      await store.updatePinned([episode(1).media!]);
      await store.write('tt123', OfflineTitleStore.videos, [
        {
          'season': 1,
          'episode': 1,
          'title': 'Saved Pilot',
          'overview': 'Saved synopsis',
          'thumbnail': 'https://unused.test/still.jpg',
        },
        {'season': 1, 'episode': 2, 'title': 'Not downloaded'},
      ]);
      OfflineTitleStore.debugReset();
      final seasons = await downloadedSeasons([episode(1), episode(3)]);
      expect(seasons.single.episodes.map((e) => e.number), [1, 3]);
      expect(seasons.single.episodes.first.title, 'Saved Pilot');
      expect(seasons.single.episodes.first.overview, 'Saved synopsis');
      expect(
        seasons.single.episodes.first.thumbnailUrl,
        'https://unused.test/still.jpg',
      );
    },
  );

  testWidgets(
    'download shelf exposes saved art without waiting for metadata providers',
    (tester) async {
      disableRuntimeFonts();
      SharedPreferences.setMockInitialValues({});
      final item = LocalDownload(
        TaskRecord(
          DownloadTask(url: 'https://unused.test/video', filename: 'Movie.mkv'),
          TaskStatus.complete,
          1,
          1024,
        ),
        const DownloadedMedia(
          id: 'tt123',
          title: 'Saved Movie',
          type: 'movie',
          poster: 'https://unused.test/poster.jpg',
        ),
        '/tmp/movie.mkv',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DownloadsScreen(loadDownloads: () async => [item]),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      final tile = tester.widget<CatalogItemTile>(find.byType(CatalogItemTile));
      expect(tile.localOnly, isTrue);
      final image = tester.widget<RecoverableNetworkImage>(
        find.byType(RecoverableNetworkImage).first,
      );
      expect(image.imageUrl, 'https://unused.test/poster.jpg');
      expect(image.cacheManager, isNotNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'local movie detail never invokes remote metadata or recommendations',
    (tester) async {
      disableRuntimeFonts();
      SharedPreferences.setMockInitialValues({'detail_page_style': 'showcase'});
      await StorageService.getDetailPageStyle();
      var requests = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MergedDetailScreen(
            localOnly: true,
            item: const StremioMeta(
              id: 'tt123',
              type: 'movie',
              name: 'Saved Movie',
              description: 'Saved description',
              year: '2024',
            ),
            addon: StremioAddon(
              id: 'unused',
              name: 'Unused',
              manifestUrl: '',
              resources: const [],
              types: const [],
            ),
            onResume: (_) async {},
            metaEnricher: (_, _) async {
              requests++;
              return null;
            },
            recommendationsLoader: () async {
              requests++;
              return [];
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(requests, 0);
      expect(find.text('Saved Movie'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
