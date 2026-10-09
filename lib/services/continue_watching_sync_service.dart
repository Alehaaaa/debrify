import 'package:flutter/foundation.dart';

import 'simkl/simkl_continue_watching_service.dart';
import 'simkl/simkl_service.dart';
import 'storage_service.dart';
import 'trakt/trakt_continue_watching_service.dart';
import 'trakt/trakt_service.dart';
import 'watchlist_sync_service.dart';
import 'watch_history_sync_service.dart';
import 'profiles/profile_runtime.dart';

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
      StorageService.clearPlaybackStateByImdbId(
        imdbId,
        preserveFinishedEpisodes: true,
      ),
      _removeTrakt(imdbId, type),
      _removeSimkl(imdbId, type),
    ]);
  }

  static Future<ContinueWatchingMatchResult>? _autoMatchInFlight;
  static DateTime? _lastAutoMatch;
  static Object? _lastScope;
  static Future<ContinueWatchingMatchResult>? _matchInFlight;
  static Object? _matchScope;
  static int? _matchRevision;
  static int? _lastRevision;

  /// Background match while sync is on (app start, Home reloads). Throttled so
  /// row reloads it triggers don't loop. Returns null when it didn't run.
  static Future<ContinueWatchingMatchResult?> autoMatch({
    Duration minInterval = const Duration(minutes: 10),
  }) async {
    if (!await enabled()) return null;
    final inFlight = _autoMatchInFlight;
    if (inFlight != null &&
        _lastScope == ProfileRuntime.scope.value &&
        _lastRevision == StorageService.trackingSourceRevision.value) {
      return inFlight;
    }
    final scope = ProfileRuntime.scope.value;
    if (_lastScope != scope ||
        _lastRevision != StorageService.trackingSourceRevision.value) {
      _lastRevision = StorageService.trackingSourceRevision.value;
      _lastAutoMatch = null;
      _lastScope = scope;
    }
    final last = _lastAutoMatch;
    if (last != null && DateTime.now().difference(last) < minInterval) {
      return null;
    }
    _lastAutoMatch = DateTime.now();
    final run = matchAll();
    _autoMatchInFlight = run;
    try {
      final result = await run;
      if (result.historyFailed > 0) _lastAutoMatch = null;
      return result;
    } catch (error) {
      _lastAutoMatch = null;
      debugPrint('Tracker sync interrupted: ${error.runtimeType}');
      return null;
    } finally {
      if (identical(_autoMatchInFlight, run)) _autoMatchInFlight = null;
    }
  }

  /// Reads Continue Watching from Debrify, Trakt and Simkl, picks the furthest
  /// point for every title (later episode wins; same episode → higher percent)
  /// and brings every owner that is missing the title or behind up to it.
  /// Remote owners get a paused session at that point; Debrify gets the title
  /// plus a resume position when the runtime is known. A tracker whose list
  /// can't be read is skipped rather than treated as empty.
  static Future<ContinueWatchingMatchResult> matchAll() async {
    final scope = ProfileRuntime.scope.value;
    if (_matchInFlight != null &&
        _matchScope == scope &&
        _matchRevision == StorageService.trackingSourceRevision.value) {
      return _matchInFlight!;
    }
    _matchScope = scope;
    _matchRevision = StorageService.trackingSourceRevision.value;
    final run = _matchAll();
    _matchInFlight = run;
    try {
      return await run;
    } finally {
      if (identical(_matchInFlight, run)) _matchInFlight = null;
    }
  }

  static Future<ContinueWatchingMatchResult> _matchAll() async {
    final scope = ProfileRuntime.scope.value;
    final revision = StorageService.trackingSourceRevision.value;
    Future<void> checkCurrent() async {
      if (scope != ProfileRuntime.scope.value ||
          revision != StorageService.trackingSourceRevision.value ||
          !await enabled()) {
        throw StateError(
          'Sync stopped because the profile or sync setting changed',
        );
      }
    }

    await checkCurrent();
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
          updatedAtMs: item['updatedAt'] as int?,
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
            updatedAtMs: item.pausedAtMs,
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
            updatedAtMs: item.pausedAtMs,
          ),
          atSimkl,
        );
      }
    }

    // When each title was really last watched. Trackers record every play
    // (sync scrobbles local playback too), so their time wins unless Debrify is
    // ahead of all of them — then its own playback time is newer. Local times
    // written by earlier syncs are therefore ignored and get corrected.
    int? watchedAt(String key) {
      final l = atLocal[key], t = atTrakt[key], s = atSimkl[key];
      final trackerTime = _MatchEntry._latest(t?.updatedAtMs, s?.updatedAtMs);
      if (l == null) return trackerTime;
      if (trackerTime == null) return l.updatedAtMs;
      final localAhead = [t, s].whereType<_MatchEntry>().every(l.isAheadOf);
      return localAhead
          ? _MatchEntry._latest(l.updatedAtMs, trackerTime)
          : trackerTime;
    }

    // Titles missing locally are imported in one write at their watched
    // time, so they slot in chronologically instead of pushing titles out.
    final imports = <Map<String, dynamic>>[
      for (final MapEntry(key: key, value: target) in best.entries)
        if (!atLocal.containsKey(key))
          {
            'imdbId': target.imdbId,
            'title': target.title,
            'contentType': target.contentType,
            'posterUrl': target.posterUrl,
            'year': target.year,
            if (watchedAt(key) case final int at) 'updatedAt': at,
          },
    ];
    await checkCurrent();
    var toLocal = await StorageService.importContinueWatchingItems(imports);
    var toTrakt = 0, toSimkl = 0;
    for (final MapEntry(key: key, value: target) in best.entries) {
      await checkCurrent();
      final localEntry = atLocal[key];
      if ((localEntry == null || target.isAheadOf(localEntry)) &&
          await _writeLocalPosition(
            target,
            local: localEntry,
            watchedAtMs: watchedAt(key),
          ) &&
          localEntry != null) {
        toLocal++;
      }
      if (!target.resumable) continue;
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
    // Re-date titles already in local Continue Watching (including ones an
    // earlier sync stamped with the sync time) so the rows stay chronological.
    await StorageService.setContinueWatchingTimes({
      for (final key in atLocal.keys)
        if (watchedAt(key) case final int at) key: at,
    });
    await checkCurrent();
    WatchlistSyncResult watchlist;
    try {
      watchlist = await WatchlistSyncService.sync();
    } catch (e) {
      debugPrint('ContinueWatchingSync: watchlist sync failed: $e');
      watchlist = const WatchlistSyncResult();
    }
    await checkCurrent();
    final history = await WatchHistorySyncService.sync();
    return ContinueWatchingMatchResult(
      historyChanged: history.changed,
      historyFailed: history.failed,
      watchlistAdded: watchlist.added,
      watchlistRemoved: watchlist.removed,
      addedToDebrify: toLocal,
      addedToTrakt: toTrakt,
      addedToSimkl: toSimkl,
      traktSkipped: traktAuthed && !traktReadable,
      simklSkipped: simklAuthed && !simklReadable,
    );
  }

  /// Brings Debrify's own position for [target] up to date. With a known
  /// runtime (Trakt movies, or a show's last local episode) it writes a real
  /// resume position. A show without one gets an episode pointer: a
  /// zero-length state the app reads as "last played episode", so the card
  /// and Continue open that episode while the percent stays with the tracker.
  static Future<bool> _writeLocalPosition(
    _MatchEntry target, {
    _MatchEntry? local,
    int? watchedAtMs,
  }) async {
    final isSeries = target.contentType == 'series';
    if (isSeries && (target.season == null || target.episode == null)) {
      return false;
    }
    if (!isSeries && !target.resumable) return false;
    final minutes =
        target.runtimeMinutes ?? (isSeries ? local?.runtimeMinutes : null);
    final started = target.resumable;
    final durationMs = minutes != null && minutes > 0 && started
        ? minutes * 60000
        : 0;
    if (durationMs == 0) {
      if (!isSeries) return false;
      // Already pointing at this episode — rewriting would only churn.
      if (local != null &&
          local.season == target.season &&
          local.episode == target.episode &&
          (watchedAtMs == null || local.stateUpdatedAtMs == watchedAtMs)) {
        return false;
      }
    }
    final positionMs = durationMs == 0
        ? 0
        : (durationMs * target.progress! / 100).round();
    try {
      if (isSeries) {
        await StorageService.saveSeriesPlaybackState(
          seriesTitle: target.title,
          season: target.season!,
          episode: target.episode!,
          positionMs: positionMs,
          durationMs: durationMs,
          imdbId: target.imdbId,
          recoveryUpdatedAtMs: watchedAtMs,
        );
      } else {
        await StorageService.saveVideoPlaybackState(
          videoTitle: target.title,
          videoUrl: '',
          positionMs: positionMs,
          durationMs: durationMs,
          imdbId: target.imdbId,
          recoveryUpdatedAtMs: watchedAtMs,
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
    ({
      double? progress,
      int? season,
      int? episode,
      int? runtimeMinutes,
      int? updatedAtMs,
    })
  >
  _localState(String imdbId, String contentType) async {
    const none = (
      progress: null,
      season: null,
      episode: null,
      runtimeMinutes: null,
      updatedAtMs: null,
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
        updatedAtMs: (state['updatedAt'] as num?)?.toInt(),
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
  final int watchlistAdded;
  final int watchlistRemoved;
  final int historyChanged;
  final int historyFailed;

  const ContinueWatchingMatchResult({
    this.historyChanged = 0,
    this.historyFailed = 0,
    this.watchlistAdded = 0,
    this.watchlistRemoved = 0,
    required this.addedToDebrify,
    required this.addedToTrakt,
    required this.addedToSimkl,
    this.traktSkipped = false,
    this.simklSkipped = false,
  });

  int get total =>
      addedToDebrify +
      addedToTrakt +
      addedToSimkl +
      watchlistAdded +
      watchlistRemoved +
      historyChanged;

  String get summary {
    final parts = [
      if (historyChanged > 0) '$historyChanged watch history updates',
      if (historyFailed > 0) '$historyFailed history transfers need retry',
      if (addedToDebrify > 0) '$addedToDebrify in Debrify',
      if (addedToTrakt > 0) '$addedToTrakt on Trakt',
      if (addedToSimkl > 0) '$addedToSimkl on Simkl',
    ];
    if (watchlistAdded > 0) parts.add('$watchlistAdded watchlist adds');
    if (watchlistRemoved > 0) parts.add('$watchlistRemoved watchlist removals');
    final skipped = [if (traktSkipped) 'Trakt', if (simklSkipped) 'Simkl'];
    final base = parts.isEmpty
        ? 'Watch history, Continue Watching and watchlists already in sync'
        : 'Synced: ${parts.join(', ')}';
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

  /// When this owner last saw playback (epoch ms), used as local recency.
  final int? updatedAtMs;

  /// Debrify only: `updatedAt` of the saved playback state itself.
  final int? stateUpdatedAtMs;

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
    this.updatedAtMs,
    this.stateUpdatedAtMs,
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
    ({
      double? progress,
      int? season,
      int? episode,
      int? runtimeMinutes,
      int? updatedAtMs,
    })
    value,
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
    updatedAtMs: _latest(updatedAtMs, value.updatedAtMs),
    stateUpdatedAtMs: value.updatedAtMs,
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
    updatedAtMs: _latest(updatedAtMs, other.updatedAtMs),
  );

  static int? _latest(int? a, int? b) =>
      a == null ? b : (b == null ? a : (a > b ? a : b));
}
