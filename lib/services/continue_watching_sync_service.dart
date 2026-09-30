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

  /// First run after the toggle is switched on: reads Continue Watching from
  /// Debrify, Trakt and Simkl and copies each title to every owner that is
  /// missing it, so all lists start out matched. Remote copies are written as
  /// paused sessions at the known resume percent; titles without a resume
  /// position (e.g. Simkl "up next") are only mirrored into Debrify. A tracker
  /// whose list cannot be read is skipped rather than treated as empty, so a
  /// transient failure never floods it with duplicates.
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
    final traktReadable = traktAuthed && traktMovies != null && traktShows != null;
    final simklReadable = simklAuthed && simkl != null;

    final entries = <String, _MatchEntry>{};
    final inLocal = <String>{};
    final inTrakt = <String>{};
    final inSimkl = <String>{};

    void merge(_MatchEntry entry, Set<String> owner) {
      final key = entry.imdbId.trim().toLowerCase();
      if (key.isEmpty) return;
      owner.add(key);
      final existing = entries[key];
      entries[key] = existing == null ? entry : existing.fillFrom(entry);
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
        ).withProgress(await _localProgress(id, type)),
        inLocal,
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
          ),
          inTrakt,
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
          inSimkl,
        );
      }
    }

    var toLocal = 0, toTrakt = 0, toSimkl = 0;
    for (final MapEntry(key: key, value: entry) in entries.entries) {
      if (!inLocal.contains(key)) {
        await StorageService.saveContinueWatchingItem(
          imdbId: entry.imdbId,
          title: entry.title,
          contentType: entry.contentType,
          posterUrl: entry.posterUrl,
          year: entry.year,
        );
        toLocal++;
      }
      if (!entry.resumable) continue;
      final progress = entry.progress!;
      if (traktReadable && !inTrakt.contains(key)) {
        try {
          if (await TraktService.instance.scrobblePause(
            entry.imdbId,
            progress,
            season: entry.season,
            episode: entry.episode,
            contentType: entry.contentType,
          )) {
            toTrakt++;
          }
        } catch (e) {
          debugPrint('ContinueWatchingSync: Trakt copy failed $key: $e');
        }
      }
      if (simklReadable && !inSimkl.contains(key)) {
        try {
          if (await SimklService.instance.scrobblePause(
            entry.imdbId,
            progress,
            season: entry.season,
            episode: entry.episode,
          )) {
            toSimkl++;
          }
        } catch (e) {
          debugPrint('ContinueWatchingSync: Simkl copy failed $key: $e');
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

  /// Local resume percent + episode for a Debrify Continue Watching title.
  static Future<({double? progress, int? season, int? episode})> _localProgress(
    String imdbId,
    String contentType,
  ) async {
    try {
      final state = contentType == 'series'
          ? await StorageService.getLastPlayedEpisodeByImdbId(imdbId)
          : await StorageService.getVideoPlaybackStateByImdbId(imdbId);
      if (state == null || state['finished'] == true) {
        return (progress: null, season: null, episode: null);
      }
      final position = (state['positionMs'] as num?)?.toDouble() ?? 0;
      final duration = (state['durationMs'] as num?)?.toDouble() ?? 0;
      return (
        progress: duration > 0 ? position / duration * 100 : null,
        season: state['season'] as int?,
        episode: state['episode'] as int?,
      );
    } catch (_) {
      return (progress: null, season: null, episode: null);
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
      if (item != null) {
        await service.removeItem(item);
      } else {
        await TraktService.instance.removeFromHistory(imdbId, contentType);
      }
    } catch (_) {}
  }

  static Future<void> _removeSimkl(String imdbId, String type) async {
    if (!await SimklService.instance.isAuthenticated()) return;
    try {
      await Future.wait([
        SimklService.instance.deletePlaybackForImdb(imdbId, contentType: type),
        SimklService.instance.removeFromList(imdbId, type),
      ]);
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
      if (addedToDebrify > 0) '$addedToDebrify to Debrify',
      if (addedToTrakt > 0) '$addedToTrakt to Trakt',
      if (addedToSimkl > 0) '$addedToSimkl to Simkl',
    ];
    final skipped = [
      if (traktSkipped) 'Trakt',
      if (simklSkipped) 'Simkl',
    ];
    final base = parts.isEmpty
        ? 'Continue Watching already matched'
        : 'Continue Watching matched: added ${parts.join(', ')}';
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
  final double? progress;
  final int? season;
  final int? episode;

  const _MatchEntry({
    required this.imdbId,
    required this.contentType,
    required this.title,
    this.posterUrl,
    this.year,
    this.progress,
    this.season,
    this.episode,
  });

  /// A paused session other trackers can accept: started, not finished, and
  /// for series pinned to a concrete episode.
  bool get resumable =>
      progress != null &&
      progress! > 0 &&
      progress! < 80 &&
      (contentType != 'series' || (season != null && episode != null));

  _MatchEntry withProgress(
    ({double? progress, int? season, int? episode}) value,
  ) => _MatchEntry(
    imdbId: imdbId,
    contentType: contentType,
    title: title,
    posterUrl: posterUrl,
    year: year,
    progress: value.progress,
    season: value.season,
    episode: value.episode,
  );

  /// Keeps this entry's data and fills gaps (poster, year, resume point) from
  /// another owner's copy of the same title.
  _MatchEntry fillFrom(_MatchEntry other) {
    final useOther = !resumable && other.resumable;
    return _MatchEntry(
      imdbId: imdbId,
      contentType: contentType,
      title: title.isEmpty || title == imdbId ? other.title : title,
      posterUrl: posterUrl ?? other.posterUrl,
      year: year ?? other.year,
      progress: useOther ? other.progress : progress,
      season: useOther ? other.season : season,
      episode: useOther ? other.episode : episode,
    );
  }
}
