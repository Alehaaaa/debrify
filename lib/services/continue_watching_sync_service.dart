import 'package:flutter/foundation.dart';

import 'simkl/simkl_continue_watching_service.dart';
import 'simkl/simkl_service.dart';
import 'storage_service.dart';
import 'trakt/trakt_continue_watching_service.dart';
import 'trakt/trakt_service.dart';

/// Removes a title from every Continue Watching owner when unified tracking is
/// enabled. Each remote operation is best-effort so one disconnected account
/// never prevents the other owners from being cleaned up.
class ContinueWatchingSyncService {
  const ContinueWatchingSyncService._();

  static Future<bool> enabled() => StorageService.getSyncAllContinueWatching();

  static Future<void> removeEverywhere({
    required String imdbId,
    required String contentType,
  }) async {
    if (!await enabled()) return;
    final type = contentType == 'series' ? 'series' : 'movie';
    await Future.wait([
      StorageService.removeContinueWatchingItem(imdbId),
      StorageService.clearPlaybackStateByImdbId(imdbId),
      _removeTrakt(imdbId, type),
      _removeSimkl(imdbId, type),
    ]);
  }

  static Future<ContinueWatchingMatchResult>? _autoMatchInFlight;
  static DateTime? _lastAutoMatch;

  /// Background match while sync is on (app start, Home reloads). Throttled so
  /// row reloads it triggers don't loop. Returns null when it didn't run.
  static Future<ContinueWatchingMatchResult?> autoMatch({
    Duration minInterval = const Duration(minutes: 10),
  }) async {
    if (!await enabled()) return null;
    final inFlight = _autoMatchInFlight;
    if (inFlight != null) return inFlight;
    final last = _lastAutoMatch;
    if (last != null && DateTime.now().difference(last) < minInterval) {
      return null;
    }
    _lastAutoMatch = DateTime.now();
    final run = matchAll();
    _autoMatchInFlight = run;
    try {
      return await run;
    } finally {
      _autoMatchInFlight = null;
    }
  }

  /// Reads Continue Watching from Debrify, Trakt and Simkl, picks the furthest
  /// point for every title (later episode wins; same episode → higher percent)
  /// and brings every owner that is missing the title or behind up to it.
  /// Remote owners get a paused session at that point; Debrify gets the title
  /// plus a resume position when the runtime is known. A tracker whose list
  /// can't be read is skipped rather than treated as empty.
  static Future<ContinueWatchingMatchResult> matchAll() async {
    final traktAuthed = await TraktService.instance.isAuthenticated();
    final simklAuthed = await SimklService.instance.isAuthenticated();
    final traktService = TraktContinueWatchingService.instance;
    final results = await Future.wait<Object?>([
      StorageService.getContinueWatchingItems(),
      traktAuthed ? traktService.fetchMoviesOrNull() : Future.value(null),
      traktAuthed ? traktService.fetchShowsOrNull() : Future.value(null),
      simklAuthed
          ? SimklContinueWatchingService.instance.fetchItems()
          : Future.value(null),
    ]);
    final local = results[0] as List<Map<String, dynamic>>;
    final traktMovies = results[1] as List<TraktContinueWatchingItem>?;
    final traktShows = results[2] as List<TraktContinueWatchingItem>?;
    final simkl =
        results[3]
            as ({
              List<SimklContinueWatchingItem> movies,
              List<SimklContinueWatchingItem> shows,
            })?;
    final traktReadable =
        traktAuthed && traktMovies != null && traktShows != null;
    final simklReadable = simklAuthed && simkl != null;

    final best = <String, _MatchEntry>{};
    final atLocal = <String, _MatchEntry>{};
    final atTrakt = <String, _MatchEntry>{};
    final atSimkl = <String, _MatchEntry>{};

    void merge(_MatchEntry entry, Map<String, _MatchEntry> owner) {
      final key = entry.key;
      if (key.isEmpty) return;
      final had = owner[key];
      owner[key] = had == null || entry.isAheadOf(had) ? entry : had;
      final current = best[key];
      best[key] = current == null
          ? entry
          : entry.isAheadOf(current)
          ? entry.fillFrom(current)
          : current.fillFrom(entry);
    }

    for (final item in local) {
      final id = item['imdbId'] as String? ?? '';
      final type = item['contentType'] as String? ?? 'movie';
      merge(
        _MatchEntry(
          imdbId: id,
          contentType: type,
          title: item['title'] as String? ?? id,
          posterUrl: item['posterUrl'] as String?,
          year: item['year'] as String?,
        ).withLocalState(await _localState(id, type)),
        atLocal,
      );
    }
    if (traktReadable) {
      for (final item in [...traktMovies, ...traktShows]) {
        merge(
          _MatchEntry(
            imdbId: item.id,
            contentType: item.isSeries ? 'series' : 'movie',
            title: item.title,
            posterUrl: item.posterUrl,
            year: item.year,
            progress: item.progress,
            season: item.season,
            episode: item.episode,
            runtimeMinutes: item.isSeries ? null : item.runtime,
          ),
          atTrakt,
        );
      }
    }
    if (simklReadable) {
      for (final item in [...simkl.movies, ...simkl.shows]) {
        merge(
          _MatchEntry(
            imdbId: item.id,
            contentType: item.isSeries ? 'series' : 'movie',
            title: item.meta.name,
            posterUrl: item.meta.poster,
            year: item.meta.year,
            progress: item.progress,
            season: item.season,
            episode: item.episode,
          ),
          atSimkl,
        );
      }
    }

    var toLocal = 0, toTrakt = 0, toSimkl = 0;
    for (final MapEntry(key: key, value: target) in best.entries) {
      final localEntry = atLocal[key];
      if (localEntry == null) {
        await StorageService.saveContinueWatchingItem(
          imdbId: target.imdbId,
          title: target.title,
          contentType: target.contentType,
          posterUrl: target.posterUrl,
          year: target.year,
        );
        toLocal++;
      }
      if (!target.resumable) continue;
      if ((localEntry == null || target.isAheadOf(localEntry)) &&
          await _writeLocalPosition(
            target,
            fallbackRuntimeMinutes: localEntry?.runtimeMinutes,
          )) {
        if (localEntry != null) toLocal++;
      }
      final traktEntry = atTrakt[key];
      if (traktReadable &&
          (traktEntry == null || target.isAheadOf(traktEntry))) {
        try {
          if (await TraktService.instance.scrobblePause(
            target.imdbId,
            target.progress!,
            season: target.season,
            episode: target.episode,
            contentType: target.contentType,
          )) {
            toTrakt++;
          }
        } catch (e) {
          debugPrint('ContinueWatchingSync: Trakt update failed $key: $e');
        }
      }
      final simklEntry = atSimkl[key];
      if (simklReadable &&
          (simklEntry == null || target.isAheadOf(simklEntry))) {
        try {
          if (await SimklService.instance.scrobblePause(
            target.imdbId,
            target.progress!,
            season: target.season,
            episode: target.episode,
          )) {
            toSimkl++;
          }
        } catch (e) {
          debugPrint('ContinueWatchingSync: Simkl update failed $key: $e');
        }
      }
    }
    if (toTrakt > 0) await traktService.clearCachedItems();
    return ContinueWatchingMatchResult(
      addedToDebrify: toLocal,
      addedToTrakt: toTrakt,
      addedToSimkl: toSimkl,
      traktSkipped: traktAuthed && !traktReadable,
      simklSkipped: simklAuthed && !simklReadable,
    );
  }

  /// Writes a Debrify resume position for [target] when a runtime is known
  /// (Trakt movies carry one, a series can borrow its last local episode's). Without it a guessed duration would make the
  /// player seek to the wrong time, so the title is only listed.
  static Future<bool> _writeLocalPosition(
    _MatchEntry target, {
    int? fallbackRuntimeMinutes,
  }) async {
    // A series falls back to the runtime of the last locally played episode
    // of the same show, which is a close estimate for its next episodes.
    final minutes = target.runtimeMinutes ?? fallbackRuntimeMinutes;
    if (minutes == null || minutes <= 0) return false;
    final durationMs = minutes * 60000;
    final positionMs = (durationMs * target.progress! / 100).round();
    try {
      if (target.contentType == 'series') {
        await StorageService.saveSeriesPlaybackState(
          seriesTitle: target.title,
          season: target.season!,
          episode: target.episode!,
          positionMs: positionMs,
          durationMs: durationMs,
          imdbId: target.imdbId,
        );
      } else {
        await StorageService.saveVideoPlaybackState(
          videoTitle: target.title,
          videoUrl: '',
          positionMs: positionMs,
          durationMs: durationMs,
          imdbId: target.imdbId,
        );
      }
      return true;
    } catch (e) {
      debugPrint('ContinueWatchingSync: local position failed: $e');
      return false;
    }
  }

  /// Local resume point for a Debrify Continue Watching title. A finished
  /// episode counts as 100% of that episode.
  static Future<
    ({double? progress, int? season, int? episode, int? runtimeMinutes})
  >
  _localState(String imdbId, String contentType) async {
    const none = (
      progress: null,
      season: null,
      episode: null,
      runtimeMinutes: null,
    );
    try {
      final state = contentType == 'series'
          ? await StorageService.getLastPlayedEpisodeByImdbId(imdbId)
          : await StorageService.getVideoPlaybackStateByImdbId(imdbId);
      if (state == null) return none;
      final position = (state['positionMs'] as num?)?.toDouble() ?? 0;
      final duration = (state['durationMs'] as num?)?.toDouble() ?? 0;
      final progress = state['finished'] == true
          ? 100.0
          : duration > 0
          ? (position / duration * 100).clamp(0.0, 100.0)
          : null;
      return (
        progress: progress,
        season: state['season'] as int?,
        episode: state['episode'] as int?,
        runtimeMinutes: duration > 60000 ? (duration / 60000).round() : null,
      );
    } catch (_) {
      return none;
    }
  }

  static Future<void> _removeTrakt(String imdbId, String contentType) async {
    if (!await TraktService.instance.isAuthenticated()) return;
    try {
      final service = TraktContinueWatchingService.instance;
      final lists = await Future.wait([
        service.fetchMoviesOrNull(),
        service.fetchShowsOrNull(),
      ]);
      final item = [...?lists[0], ...?lists[1]]
          .cast<TraktContinueWatchingItem?>()
          .firstWhere((item) => item?.id == imdbId, orElse: () => null);
      // Only the paused session goes; watched history stays untouched.
      if (item != null) await service.removeItem(item);
    } catch (_) {}
  }

  static Future<void> _removeSimkl(String imdbId, String type) async {
    if (!await SimklService.instance.isAuthenticated()) return;
    // Same as Simkl's own "Remove from Continue Watching": a series is parked
    // On Hold (keeps its watched episodes), a movie just loses its session.
    // Never removeFromList — that wipes the title's Simkl history.
    try {
      if (type == 'series') {
        await SimklService.instance.addToList(imdbId, type, 'hold');
      }
      await SimklService.instance.deletePlaybackForImdb(
        imdbId,
        contentType: type,
      );
    } catch (_) {}
  }
}

class ContinueWatchingMatchResult {
  final int addedToDebrify;
  final int addedToTrakt;
  final int addedToSimkl;
  final bool traktSkipped;
  final bool simklSkipped;

  const ContinueWatchingMatchResult({
    required this.addedToDebrify,
    required this.addedToTrakt,
    required this.addedToSimkl,
    this.traktSkipped = false,
    this.simklSkipped = false,
  });

  int get total => addedToDebrify + addedToTrakt + addedToSimkl;

  String get summary {
    final parts = [
      if (addedToDebrify > 0) '$addedToDebrify in Debrify',
      if (addedToTrakt > 0) '$addedToTrakt on Trakt',
      if (addedToSimkl > 0) '$addedToSimkl on Simkl',
    ];
    final skipped = [
      if (traktSkipped) 'Trakt',
      if (simklSkipped) 'Simkl',
    ];
    final base = parts.isEmpty
        ? 'Continue Watching already matched'
        : 'Continue Watching synced: updated ${parts.join(', ')}';
    return skipped.isEmpty
        ? base
        : '$base (${skipped.join(' and ')} unreachable, skipped)';
  }
}

class _MatchEntry {
  final String imdbId;
  final String contentType;
  final String title;
  final String? posterUrl;
  final String? year;

  /// 0–100. Null for an "up next" row that hasn't been started.
  final double? progress;
  final int? season;
  final int? episode;
  final int? runtimeMinutes;

  const _MatchEntry({
    required this.imdbId,
    required this.contentType,
    required this.title,
    this.posterUrl,
    this.year,
    this.progress,
    this.season,
    this.episode,
    this.runtimeMinutes,
  });

  String get key => imdbId.trim().toLowerCase();

  /// A paused session trackers accept: started, not finished (both Trakt and
  /// Simkl turn ≥80% into a watch), and for series pinned to an episode.
  bool get resumable =>
      progress != null &&
      progress! >= 1 &&
      progress! < 80 &&
      (contentType != 'series' || (season != null && episode != null));

  /// Later episode wins; the same episode (or a movie) compares by percent,
  /// ignoring sub-2% drift so owners that already agree aren't rewritten.
  bool isAheadOf(_MatchEntry other) {
    if (contentType == 'series') {
      final s = season ?? 0, o = other.season ?? 0;
      if (s != o) return s > o;
      final e = episode ?? 0, oe = other.episode ?? 0;
      if (e != oe) return e > oe;
    }
    return (progress ?? 0) - (other.progress ?? 0) > 2;
  }

  _MatchEntry withLocalState(
    ({double? progress, int? season, int? episode, int? runtimeMinutes}) value,
  ) => _MatchEntry(
    imdbId: imdbId,
    contentType: contentType,
    title: title,
    posterUrl: posterUrl,
    year: year,
    progress: value.progress,
    season: value.season,
    episode: value.episode,
    runtimeMinutes: value.runtimeMinutes,
  );

  /// Keeps this entry's position and fills metadata gaps from [other]. The
  /// runtime is only borrowed for movies (a series runtime is per episode).
  _MatchEntry fillFrom(_MatchEntry other) => _MatchEntry(
    imdbId: imdbId,
    contentType: contentType,
    title: title.isEmpty || title == imdbId ? other.title : title,
    posterUrl: posterUrl ?? other.posterUrl,
    year: year ?? other.year,
    progress: progress,
    season: season,
    episode: episode,
    runtimeMinutes:
        runtimeMinutes ??
        (contentType == 'series' ? null : other.runtimeMinutes),
  );
}
