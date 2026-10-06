import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import '../models/downloaded_media.dart';
import '../utils/app_storage.dart';
import '../utils/movie_parser.dart';
import 'download_service.dart';
import 'profiles/profile_runtime.dart';
import 'local_playback_resume_resolver.dart';
import 'offline_title_store.dart';
import 'movie_metadata_service.dart';
import 'tvmaze_service.dart';
import 'video_player_launcher.dart';

class LocalDownload {
  final TaskRecord record;
  final DownloadedMedia? media;
  final String location;

  /// Download-queue records describing this same file (a finished file found
  /// on disk may have one; a retried download may have several). Removing the
  /// download clears them too.
  final List<TaskRecord> linkedRecords;
  const LocalDownload(
    this.record,
    this.media,
    this.location, {
    this.linkedRecords = const [],
  });
  bool get isReady =>
      record.status == TaskStatus.complete && location.isNotEmpty;
  String get title => media?.title ?? record.task.filename;
  String get groupKey => media?.key ?? 'file:${record.taskId}';

  /// Found by scanning the download folder rather than from a queue record.
  bool get isScanned =>
      record.taskId.startsWith(DownloadedMediaService.scannedTaskPrefix);
}

/// The local library.
///
/// Finished downloads come from the download folder itself: it is scanned for
/// video files every time the library loads, so whatever is on disk is what
/// the library shows — files moved in by hand included, deleted files gone.
/// Catalog identity (which title/episode a file is) is cached per file path
/// once known, from the download that produced it; files without a cached
/// identity are recognised from their name. In-flight transfers still come
/// from the download queue. Android keeps the queue as its source of
/// finished files too: they live in MediaStore / a SAF folder, which can't be
/// listed by path.
class DownloadedMediaService {
  static const scannedTaskPrefix = 'local-file:';

  static const _videoExtensions = {
    '.mkv',
    '.mp4',
    '.m4v',
    '.mov',
    '.avi',
    '.webm',
    '.ts',
    '.m2ts',
    '.wmv',
    '.flv',
    '.mpg',
    '.mpeg',
    '.3gp',
    '.ogv',
  };

  @visibleForTesting
  static Future<List<String>> Function()? debugFolders;
  @visibleForTesting
  static Future<File> Function()? debugCacheFile;
  @visibleForTesting
  static Future<List<TaskRecord>> Function()? debugRecords;

  static Future<List<LocalDownload>>? _inFlight;

  @visibleForTesting
  static void debugResetCache() => _MediaCache.reset();

  static Future<List<LocalDownload>>? _queued;

  static Future<List<LocalDownload>> load({bool includeTransfers = false}) {
    return _shared().then(
      (items) =>
          includeTransfers ? items : items.where((e) => e.isReady).toList(),
    );
  }

  /// Several widgets (library, detail-page Download buttons) refresh on the
  /// same download events. They share scans, but a request made while a scan
  /// is running gets the NEXT scan — reusing the running one could return a
  /// picture taken before the download that triggered the request finished.
  static Future<List<LocalDownload>> _shared() {
    final running = _inFlight;
    if (running == null) return _start();
    return _queued ??= running.then<void>((_) {}, onError: (_) {}).then((_) {
      _queued = null;
      return _start();
    });
  }

  static Future<List<LocalDownload>> _start() {
    final future = _load();
    _inFlight = future;
    future.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      if (identical(_inFlight, future)) _inFlight = null;
    });
    return future;
  }

  static String? _activeProfile() => ProfileRuntime.isProfileCommitted
      ? ProfileRuntime.capture().profileId
      : null;

  static String _norm(String path) => p.normalize(path);

  static Future<List<LocalDownload>> _load() async {
    final owner = _activeProfile();
    final service = DownloadService.instance;
    final List<TaskRecord> records;
    if (debugRecords != null) {
      records = await debugRecords!();
    } else {
      await service.initializeLibrary();
      records = await service.allRecords();
      unawaited(
        service.initialize().catchError((Object error) {
          debugPrint('Downloads: transfer startup deferred ($error)');
        }),
      );
    }
    final cache = await _MediaCache.open();

    // Queue records: finished ones by the file they produced, unfinished
    // ones kept as transfers.
    final finishedByPath = <String, List<TaskRecord>>{};
    final finishedMeta = <String, DownloadedMedia?>{};
    final contentUriItems = <LocalDownload>[];
    final transfers = <LocalDownload>[];
    final inFlightPaths = <String>{};
    for (final record in records) {
      final details = service.recordDetailsForTaskId(record.taskId);
      final media =
          cache.manualFor(null, [record.taskId]) ??
          DownloadedMedia.fromMetadata(details?.meta) ??
          DownloadedMedia.fromFilename(
            record.task.filename,
            packName: details?.torrentName,
          );
      String? pluginPath;
      try {
        pluginPath = await record.task.filePath();
      } catch (_) {}
      final candidates = <String>[
        if (details?.destPath != null) details!.destPath!,
        if (service.getLastFileForTask(record.taskId) != null)
          service.getLastFileForTask(record.taskId)!.$1,
        ?pluginPath,
      ];
      if (record.status != TaskStatus.complete) {
        if (record.status == TaskStatus.canceled ||
            record.status == TaskStatus.notFound) {
          continue;
        }
        // A partly written file in the download folder is not a download.
        inFlightPaths.addAll(
          candidates.where((c) => !c.startsWith('content://')).map(_norm),
        );
        transfers.add(LocalDownload(record, media, ''));
        continue;
      }
      for (final location in candidates) {
        if (location.startsWith('content://')) {
          contentUriItems.add(LocalDownload(record, media, location));
          break;
        }
        if (await File(location).exists()) {
          final key = _norm(location);
          finishedByPath.putIfAbsent(key, () => []).add(record);
          finishedMeta[key] ??= DownloadedMedia.fromMetadata(details?.meta);
          break;
        }
      }
    }

    // The download folder is the source of truth for finished files.
    final scanned = <String, FileStat>{};
    final folders = await (debugFolders?.call() ?? service.libraryFolders());
    for (final folder in folders) {
      final dir = Directory(folder);
      if (!await dir.exists()) continue;
      try {
        await for (final entity in dir.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (name.startsWith('.')) continue;
          if (!_videoExtensions.contains(p.extension(name).toLowerCase())) {
            continue;
          }
          final key = _norm(entity.path);
          if (inFlightPaths.contains(key)) continue;
          scanned[key] = await entity.stat();
        }
      } catch (_) {
        /* An unreadable folder leaves the rest of the library intact. */
      }
    }
    // Finished files saved elsewhere (an older custom folder) still count
    // while they exist.
    for (final key in finishedByPath.keys) {
      if (!scanned.containsKey(key)) {
        try {
          scanned[key] = await File(key).stat();
        } catch (_) {}
      }
    }

    final ready = <LocalDownload>[];
    final otherProfileTitles = <DownloadedMedia>[];
    for (final entry in scanned.entries) {
      final path = entry.key;
      final linked = finishedByPath[path] ?? const <TaskRecord>[];
      final cached = cache.entry(path);
      // Another profile's download stays out of this profile's library.
      if (linked.isEmpty &&
          cached?.profile != null &&
          cached!.profile != owner) {
        // Still on the device: its offline details stay too.
        if (cached.media != null) otherProfileTitles.add(cached.media!);
        continue;
      }
      // A Fix match the user made wins over everything the download or the
      // file name says — for the file, or for the transfer that produced it.
      final manual = cache.manualFor(path, [
        for (final record in linked) record.taskId,
      ]);
      if (manual != null && cached?.manual != true) {
        cache.put(path, manual, profile: owner, manual: true);
      }
      final fromRecord = finishedMeta[path];
      if (fromRecord != null && manual == null) {
        cache.put(path, fromRecord, profile: owner);
      }
      final guessed = DownloadedMedia.fromFilename(
        p.basename(path),
        packName: _packName(path, folders),
      );
      var media =
          manual ??
          fromRecord ??
          cached?.media ??
          guessed ??
          _movieCandidate(path);
      // Files copied into the download folder do not have a queue record.
      // Resolve their parsed title once, then keep the result in the same
      // path cache used for completed torrent downloads.
      if (manual == null &&
          linked.isEmpty &&
          cached?.media == null &&
          media != null) {
        final resolved = await _resolveManualMedia(media, p.basename(path));
        if (resolved != null) {
          media = resolved;
          cache.put(path, resolved, profile: owner);
        }
      }
      final record = linked.isNotEmpty
          ? linked.first
          : TaskRecord(
              DownloadTask(
                taskId: '$scannedTaskPrefix$path',
                url: Uri.file(path).toString(),
                filename: p.basename(path),
                creationTime: entry.value.modified,
              ),
              TaskStatus.complete,
              1,
              entry.value.size,
            );
      ready.add(
        LocalDownload(
          record,
          media,
          path,
          linkedRecords: linked.skip(1).toList(),
        ),
      );
    }
    cache.dropMissing();
    await cache.save();

    final result = [
      ...ready,
      ...contentUriItems,
      ..._dedupeTransfers(transfers, [...ready, ...contentUriItems]),
    ];
    // Every title on the device (or on its way) keeps its detail page
    // available offline. Marked before anyone hears about this load, so a
    // page reacting to a new download already sees it as kept.
    unawaited(
      OfflineTitleStore.instance.updatePinned([
        for (final item in [...ready, ...contentUriItems, ...transfers])
          ?item.media,
        ...otherProfileTitles,
      ]),
    );
    if (owner != _activeProfile()) return [];
    result.sort(
      (a, b) =>
          b.record.task.creationTime.compareTo(a.record.task.creationTime),
    );
    return result;
  }

  static Future<DownloadedMedia?> _resolveManualMedia(
    DownloadedMedia parsed,
    String filename,
  ) async {
    try {
      if (parsed.type == 'series') {
        final show = await TVMazeService.searchShow(parsed.title);
        if (show == null) return null;
        final imdb = show['externals'] is Map
            ? (show['externals'] as Map)['imdb'] as String?
            : null;
        if (imdb == null || imdb.isEmpty) return null;
        final image = show['image'];
        return DownloadedMedia(
          id: imdb,
          title: (show['name'] as String?) ?? parsed.title,
          type: 'series',
          poster: image is Map ? image['medium'] as String? : null,
          year: (show['premiered'] as String?)?.split('-').first,
          season: parsed.season,
          episode: parsed.episode,
        );
      }
      final movie = await MovieMetadataService.lookupFromFilename(filename);
      if (movie == null) return null;
      return DownloadedMedia(
        id: movie.imdbId,
        title: movie.title,
        type: 'movie',
        poster: movie.poster,
        year: movie.year?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  static DownloadedMedia? _movieCandidate(String path) {
    final parsed = MovieParser.parseFilename(p.basename(path));
    if (!parsed.hasYear || parsed.title == null) return null;
    return DownloadedMedia(
      id: 'download-file:${parsed.title!.toLowerCase()}',
      title: parsed.title!,
      type: 'movie',
      year: parsed.year?.toString(),
    );
  }

  /// The folder a file sits in, when that folder isn't the download root —
  /// usually the season pack it came from.
  static String? _packName(String path, List<String> roots) {
    final parent = p.dirname(path);
    if (roots.any((root) => _norm(root) == _norm(parent))) return null;
    return p.basename(parent);
  }

  static String _episodeKey(LocalDownload item) {
    final media = item.media;
    return [
      media?.key ?? '',
      media?.season ?? '',
      media?.episode ?? '',
      item.record.task.filename.toLowerCase(),
    ].join('|');
  }

  /// One row per episode/file: a retried download leaves its failed record
  /// behind next to the new one, and a transfer that has finished must not
  /// linger next to the file it produced.
  @visibleForTesting
  static List<LocalDownload> dedupeTransfers(
    List<LocalDownload> transfers,
    List<LocalDownload> finished,
  ) => _dedupeTransfers(transfers, finished);

  static List<LocalDownload> _dedupeTransfers(
    List<LocalDownload> transfers,
    List<LocalDownload> finished,
  ) {
    int rank(TaskStatus s) => switch (s) {
      TaskStatus.running => 0,
      TaskStatus.enqueued => 1,
      TaskStatus.waitingToRetry => 2,
      TaskStatus.paused => 3,
      TaskStatus.failed => 4,
      _ => 5,
    };
    final done = {
      for (final item in finished) _episodeKey(item),
      for (final item in finished) p.basename(item.location).toLowerCase(),
    };
    final best = <String, LocalDownload>{};
    for (final item in transfers) {
      if (done.contains(_episodeKey(item)) ||
          done.contains(item.record.task.filename.toLowerCase())) {
        continue;
      }
      final key = _episodeKey(item);
      final current = best[key];
      if (current == null ||
          rank(item.record.status) < rank(current.record.status) ||
          (rank(item.record.status) == rank(current.record.status) &&
              item.record.task.creationTime.isAfter(
                current.record.task.creationTime,
              ))) {
        best[key] = item;
      }
    }
    return best.values.toList();
  }

  /// Deletes a download: the file (when it's a local file) and every queue
  /// record describing it.
  static Future<void> remove(LocalDownload item) async {
    if (item.isReady && !item.location.startsWith('content://')) {
      final file = File(item.location);
      if (await file.exists()) {
        await file.delete();
        await _removeEmptyParents(file.parent);
      }
    }
    for (final record in [
      if (!item.isScanned) item.record,
      ...item.linkedRecords,
    ]) {
      try {
        await DownloadService.instance.deleteRecord(record);
      } catch (_) {}
    }
    final cache = await _MediaCache.open();
    if (item.location.isNotEmpty && !item.location.startsWith('content://')) {
      cache.remove(_norm(item.location));
    }
    for (final record in [item.record, ...item.linkedRecords]) {
      cache.remove(_MediaCache.taskKey(record.taskId));
    }
    await cache.save();
  }

  /// Tidy only folders owned by the configured download roots. This avoids
  /// walking out into a user-selected folder (or, on desktop, Downloads).
  static Future<void> _removeEmptyParents(Directory directory) async {
    final roots =
        (await (debugFolders?.call() ??
                DownloadService.instance.libraryFolders()))
            .map(_norm)
            .toSet();
    var current = directory;
    while (!roots.contains(_norm(current.path))) {
      try {
        if (!await current.exists() || !await current.list().isEmpty) return;
        final parent = current.parent;
        await current.delete();
        current = parent;
      } catch (_) {
        return;
      }
    }
  }

  static Future<void> play(BuildContext context, LocalDownload item) async {
    if (!item.isReady) return;
    if (!item.location.startsWith('content://') &&
        !await File(item.location).exists()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('This downloaded file is no longer available.'),
          ),
        );
      }
      return;
    }
    if (!context.mounted) return;
    final media = item.media;
    await VideoPlayerLauncher.push(
      context,
      VideoPlayerLaunchArgs(
        videoUrl: item.location.startsWith('content://')
            ? item.location
            : Uri.file(item.location).toString(),
        title: item.record.task.filename,
        contentTitle: item.title,
        contentImdbId: media?.isCatalogLinked == true ? media!.id : null,
        contentType: media?.type,
        contentSeason: media?.season,
        contentEpisode: media?.episode,
        posterUrl: media?.poster,
        contentYear: media?.year,
        resumePolicy: media?.isCatalogLinked != true
            ? PlaybackResumePolicy.sourceSpecific
            : PlaybackResumePolicy.catalogCanonical,
      ),
    );
  }

  static Future<bool> playMatching(
    BuildContext context,
    String id, {
    int? season,
    int? episode,
  }) async {
    // Keep normal playback immediate when no download of this title is
    // known: neither a finished queue record nor a cached file identity.
    // Synchronous on purpose: Play must not wait on disk before streaming.
    // The identity cache is read in the background the first time; detail
    // pages load it on open (their Download button), so it's warm by the
    // time anyone taps Play.
    final cache = _MediaCache.loaded;
    if (cache == null) unawaited(_MediaCache.open());
    final known =
        DownloadService.instance.allRecordDetailsSnapshot().values.any(
          (record) =>
              record.state == 'complete' &&
              DownloadedMedia.fromMetadata(record.meta)?.id == id,
        ) ||
        (cache?.hasTitle(id) ?? false);
    if (!known) return false;
    List<LocalDownload> items;
    try {
      items = await load();
    } catch (_) {
      return false;
    }
    for (final item in items) {
      final media = item.media;
      if (media?.id != id) continue;
      if (media!.type == 'series' &&
          (season == null ||
              episode == null ||
              media.season != season ||
              media.episode != episode)) {
        continue;
      }
      if (!context.mounted) return true;
      await play(context, item);
      return true;
    }
    return false;
  }
}

/// Which title/episode each downloaded file is, keyed by its path. Not a
/// list of downloads — the folder is that — just identities worth keeping
/// once known, so a file's link to its catalog title survives the queue
/// record being cleared. Entries for files no longer on disk are dropped.
class _MediaCache {
  _MediaCache._(this._file, this._entries);

  final File? _file;
  final Map<String, Map<String, dynamic>> _entries;
  bool _dirty = false;

  static _MediaCache? _memory;

  /// The cache if it has been read already; never touches disk.
  static _MediaCache? get loaded => _memory;

  static Future<_MediaCache>? _opening;

  static Future<_MediaCache> open() {
    final memory = _memory;
    if (memory != null) return Future.value(memory);
    return _opening ??= _read().whenComplete(() => _opening = null);
  }

  static Future<_MediaCache> _read() async {
    File? file;
    final entries = <String, Map<String, dynamic>>{};
    try {
      final f =
          await (DownloadedMediaService.debugCacheFile?.call() ??
              AppStorage.support().then(
                (dir) => File(p.join(dir.path, 'downloaded_media_cache.json')),
              ));
      file = f;
      if (await f.exists()) {
        final decoded = jsonDecode(await f.readAsString());
        final files = decoded is Map ? decoded['files'] : null;
        if (files is Map) {
          for (final e in files.entries) {
            if (e.key is String && e.value is Map) {
              entries[e.key as String] = Map<String, dynamic>.from(
                e.value as Map,
              );
            }
          }
        }
      }
    } catch (_) {
      /* A missing or damaged cache only costs re-recognising names. */
    }
    return _memory = _MediaCache._(file, entries);
  }

  static void reset() {
    _memory = null;
    _opening = null;
  }

  ({DownloadedMedia? media, String? profile, bool manual})? entry(String path) {
    final raw = _entries[path];
    if (raw == null) return null;
    return (
      media: DownloadedMedia.fromMetadata(jsonEncode({'media': raw['media']})),
      profile: raw['profile'] as String?,
      manual: raw['manual'] == true,
    );
  }

  /// The key a user's Fix match is kept under for a queue record, so the
  /// choice reaches the file the transfer is still writing.
  static String taskKey(String taskId) => 'task:$taskId';

  /// A user-chosen identity for [path] or any of [taskIds], if one is set.
  DownloadedMedia? manualFor(String? path, Iterable<String> taskIds) {
    for (final key in [?path, for (final id in taskIds) taskKey(id)]) {
      final e = entry(key);
      if (e != null && e.manual && e.media != null) return e.media;
    }
    return null;
  }

  bool hasTitle(String id) =>
      _entries.values.any((e) => e['media'] is Map && e['media']['id'] == id);

  void put(
    String path,
    DownloadedMedia media, {
    String? profile,
    bool manual = false,
  }) {
    final next = {
      'media': {
        'id': media.id,
        'title': media.title,
        'type': media.type,
        'poster': media.poster,
        'year': media.year,
        'season': media.season,
        'episode': media.episode,
      },
      'profile': profile,
      if (manual) 'manual': true,
    };
    if (jsonEncode(_entries[path]) == jsonEncode(next)) return;
    _entries[path] = next;
    _dirty = true;
  }

  void remove(String path) {
    if (_entries.remove(path) != null) _dirty = true;
  }

  /// Forgets files that are gone from disk. Only an existence check — a file
  /// outside this scan's folders (an unplugged drive) keeps its identity.
  void dropMissing() {
    final before = _entries.length;
    _entries.removeWhere((path, _) {
      // Queue-record keys aren't files; they go with their record (see
      // [DownloadedMediaService.remove]).
      if (path.startsWith('task:')) return false;
      try {
        return !File(path).existsSync();
      } catch (_) {
        return false;
      }
    });
    if (_entries.length != before) _dirty = true;
  }

  Future<void> save() async {
    final file = _file;
    if (!_dirty || file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'version': 1, 'files': _entries}));
      _dirty = false;
    } catch (_) {}
  }
}
