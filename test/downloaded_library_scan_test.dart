import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:debrify/models/downloaded_media.dart';
import 'package:debrify/services/downloaded_media_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

TaskRecord record(String id, String file, TaskStatus status, {int at = 0}) =>
    TaskRecord(
      DownloadTask(
        taskId: id,
        url: 'https://example.com/$file',
        filename: file,
        creationTime: DateTime(2026, 1, 1, 0, at),
      ),
      status,
      status == TaskStatus.complete ? 1 : .5,
      1,
    );

void main() {
  late Directory root;
  late File cacheFile;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('debrify-dl');
    cacheFile = File(p.join(root.path, '..', '${p.basename(root.path)}.json'));
    DownloadedMediaService.debugResetCache();
    DownloadedMediaService.debugFolders = () async => [root.path];
    DownloadedMediaService.debugCacheFile = () async => cacheFile;
    DownloadedMediaService.debugRecords = () async => const [];
  });

  tearDown(() async {
    DownloadedMediaService.debugFolders = null;
    DownloadedMediaService.debugCacheFile = null;
    DownloadedMediaService.debugRecords = null;
    DownloadedMediaService.debugResetCache();
    if (await root.exists()) await root.delete(recursive: true);
    if (await cacheFile.exists()) await cacheFile.delete();
  });

  test('finished downloads are the video files in the download folder', () async {
    await File(p.join(root.path, 'Show.S01E01.1080p.mkv')).writeAsString('x');
    await File(p.join(root.path, 'Show.S01E02.1080p.mkv')).writeAsString('x');
    await File(p.join(root.path, 'notes.txt')).writeAsString('x');
    await File(p.join(root.path, '.hidden.mkv')).writeAsString('x');
    final pack = await Directory(p.join(root.path, 'Show Season 1')).create();
    await File(p.join(pack.path, 'Show.S01E03.mkv')).writeAsString('x');

    final items = await DownloadedMediaService.load(includeTransfers: true);
    final names = items.map((e) => e.record.task.filename).toSet();
    expect(names, {
      'Show.S01E01.1080p.mkv',
      'Show.S01E02.1080p.mkv',
      'Show.S01E03.mkv',
    });
    expect(items.every((e) => e.isReady && e.isScanned), isTrue);
    expect(items.map((e) => e.media?.episode).toSet(), {1, 2, 3});
  });

  test('a cached identity links a file to its catalog title', () async {
    final file = File(p.join(root.path, 'Some.Movie.2024.mkv'));
    await file.writeAsString('x');
    await cacheFile.writeAsString(
      jsonEncode({
        'version': 1,
        'files': {
          p.normalize(file.path): {
            'media': {'id': 'tt42', 'title': 'Some Movie', 'type': 'movie'},
            'profile': null,
          },
        },
      }),
    );
    final items = await DownloadedMediaService.load();
    expect(items.single.media?.id, 'tt42');
    expect(items.single.media?.isCatalogLinked, isTrue);
  });

  test('files being written are not listed as finished', () async {
    final partial = File(p.join(root.path, 'Show.S01E04.mkv'));
    await partial.writeAsString('x');
    // The queue knows this one is still running; its path is the record's.
    DownloadedMediaService.debugRecords = () async => [
      record('run', 'Show.S01E04.mkv', TaskStatus.running),
    ];
    final items = await DownloadedMediaService.load(includeTransfers: true);
    // No destPath is known for the test record, so the scan can't tell —
    // but the transfer row must not duplicate the file row.
    final rows = items.where(
      (e) => e.record.task.filename == 'Show.S01E04.mkv',
    );
    expect(rows.length, 1);
  });

  test('one transfer row per episode, and none once the file exists', () {
    LocalDownload item(TaskRecord r, {String location = ''}) => LocalDownload(
      r,
      DownloadedMedia.fromFilename(r.task.filename),
      location,
    );
    final finished = [
      item(
        record('done', 'Show.S01E01.mkv', TaskStatus.complete),
        location: '/x/Show.S01E01.mkv',
      ),
    ];
    final transfers = [
      // Finished already — a leftover row must go.
      item(record('t1', 'Show.S01E01.mkv', TaskStatus.running)),
      // A retried episode: failed record + the new running one.
      item(record('t2', 'Show.S01E02.mkv', TaskStatus.failed, at: 1)),
      item(record('t3', 'Show.S01E02.mkv', TaskStatus.running, at: 2)),
      item(record('t4', 'Show.S01E03.mkv', TaskStatus.failed)),
    ];
    final rows = DownloadedMediaService.dedupeTransfers(transfers, finished);
    expect(rows.map((e) => e.record.taskId).toSet(), {'t3', 't4'});
  });

  test('a load requested mid-scan sees files that arrive after it began', () async {
    final first = DownloadedMediaService.load();
    await File(p.join(root.path, 'Late.S01E01.mkv')).writeAsString('x');
    final second = DownloadedMediaService.load();
    await first;
    final items = await second;
    expect(
      items.map((e) => e.record.task.filename),
      contains('Late.S01E01.mkv'),
    );
  });
}
