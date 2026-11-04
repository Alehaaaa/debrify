import 'package:flutter/foundation.dart';
import 'package:synchronized/synchronized.dart';

import '../models/stremio_addon.dart';
import 'profiles/profile_preferences.dart';
import 'simkl/simkl_item_transformer.dart';
import 'simkl/simkl_service.dart';
import 'storage_service.dart';
import 'profiles/profile_runtime.dart';
import '../models/media_identity.dart';
import 'mdblist/mdblist_service.dart';
import 'mdblist/mdblist_models.dart';
import 'trakt/trakt_list_source.dart';
import 'trakt/trakt_service.dart';

/// Only watchlist-scoped mutations are permitted on Trakt/MDBList. Simkl's
/// removeFromList endpoint ALSO deletes watched history; moving a truly
/// completed movie to Completed is the lossless transition out of Plan to Watch.
abstract class CompletedMovieWatchlistGateway {
  Future<bool> traktAuthenticated();
  Future<bool> removeFromTrakt(String imdbId);
  Future<bool> simklAuthenticated();
  Future<({bool readable, String? status})> simklStatus(String imdbId);
  Future<bool> moveSimklToCompleted(String imdbId);
  Future<bool> mdblistAuthenticated();
  Future<bool> removeFromMdblist(String imdbId);
}

class _LiveCompletedMovieWatchlistGateway
    implements CompletedMovieWatchlistGateway {
  @override
  Future<bool> traktAuthenticated() => TraktService.instance.isAuthenticated();
  @override
  Future<bool> removeFromTrakt(String id) =>
      TraktService.instance.removeFromWatchlist(id, 'movie');
  @override
  Future<bool> simklAuthenticated() => SimklService.instance.isAuthenticated();
  @override
  Future<({bool readable, String? status})> simklStatus(String id) async {
    final state = await SimklService.instance.fetchTitleStatus(
      id,
      contentType: 'movie',
    );
    return (readable: state != null, status: state?.currentStatus);
  }

  @override
  Future<bool> moveSimklToCompleted(String id) =>
      SimklService.instance.addToList(id, 'movie', 'completed');
  @override
  Future<bool> mdblistAuthenticated() =>
      MdblistService.instance.isAuthenticated();
  @override
  Future<bool> removeFromMdblist(String id) => MdblistService.instance
      .removeFromWatchlist(MdblistMediaIds.forContent(id), 'movie');
}

/// Durable journal for a completion. The bitmask acknowledges each provider
/// independently. `r` is an explicit user re-add and always beats old cleanup.
@immutable
class CompletedMovieWatchlistIntent {
  const CompletedMovieWatchlistIntent(
    this.imdbId,
    this.startedAtMs,
    this.pending,
  );
  final String imdbId;
  final int startedAtMs;
  final int pending;

  String encode() => 'p|$imdbId|$startedAtMs|$pending';
  static CompletedMovieWatchlistIntent? decode(String value) {
    final parts = value.split('|');
    if (parts.length != 4 ||
        parts[0] != 'p' ||
        !MediaIdentity.isImdb(parts[1])) {
      return null;
    }
    final at = int.tryParse(parts[2]);
    final mask = int.tryParse(parts[3]);
    if (at == null || at <= 0 || mask == null || mask < 0 || mask > 7) {
      return null;
    }
    return CompletedMovieWatchlistIntent(parts[1], at, mask);
  }
}

/// Keeps Debrify's My Watchlist, the Trakt watchlist and Simkl's Plan to
/// Watch in step while "Sync everywhere" is on.
///
/// A title on any list is added to the lists missing it. Removals travel via
/// a snapshot of what every list agreed on last time: a title that was agreed
/// and is now missing from one list was removed there, so it is removed from
/// the others too. A list that can't be read takes no part in a run.
///
/// Simkl only counts its Plan to Watch bucket. A title Simkl already tracks in
/// another status (watching, completed, …) is never moved back to Plan to
/// Watch, and Simkl removals only touch titles still in Plan to Watch.
class WatchlistSyncService {
  const WatchlistSyncService._();

  static const String _completionJournalKey = 'finished_watchlist_cleanup_v1';
  static const int _trakt = 1, _simkl = 2, _mdblist = 4;
  static final Lock _localWatchlistWriteLock = Lock();
  static CompletedMovieWatchlistGateway _gateway =
      _LiveCompletedMovieWatchlistGateway();

  @visibleForTesting
  static void debugSetCompletionGateway(
    CompletedMovieWatchlistGateway? gateway,
  ) {
    _gateway = gateway ?? _LiveCompletedMovieWatchlistGateway();
  }

  static String _id(String raw) =>
      MediaIdentity.progressId(raw, 'movie').trim().toLowerCase();

  static Future<List<String>> _journal() async =>
      (await ProfilePreferences.instance()).getStringList(
        _completionJournalKey,
      ) ??
      const <String>[];

  /// Completion must create its journal entry before asynchronous cloud writes.
  /// ProfilePreferences makes the mutation atomic across overlapping sessions.
  static Future<void> queueCompletedMovieRemoval(String rawId) async {
    final id = _id(rawId);
    if (!MediaIdentity.isImdb(id)) return;
    final scope = ProfileRuntime.scope.value;
    final prefs = await ProfilePreferences.instance();
    if (scope != ProfileRuntime.scope.value) return;
    final wrote = await prefs.mutateStringListAtomically(
      _completionJournalKey,
      (old) {
        final rows = [...?old];
        rows.removeWhere(
          (line) =>
              line == 'r|$id' ||
              CompletedMovieWatchlistIntent.decode(line)?.imdbId == id,
        );
        rows.add(
          CompletedMovieWatchlistIntent(
            id,
            DateTime.now().millisecondsSinceEpoch,
            7,
          ).encode(),
        );
        return rows;
      },
    );
    if (!wrote) throw StateError('Could not persist movie cleanup intent');
  }

  static Future<CompletedMovieWatchlistIntent?> _pending(String id) async {
    final rows = await _journal();
    if (rows.contains('r|$id')) return null;
    for (final line in rows) {
      final pending = CompletedMovieWatchlistIntent.decode(line);
      if (pending?.imdbId == id && pending!.pending != 0) return pending;
    }
    return null;
  }

  static Future<bool> _readded(String id) async =>
      (await _journal()).contains('r|$id');

  static Future<void> _explicitlyReadded(String id) async {
    if (!MediaIdentity.isImdb(id)) return;
    final prefs = await ProfilePreferences.instance();
    final wrote = await prefs.mutateStringListAtomically(
      _completionJournalKey,
      (old) {
        final rows = [...?old];
        rows.removeWhere(
          (line) =>
              line == 'r|$id' ||
              CompletedMovieWatchlistIntent.decode(line)?.imdbId == id,
        );
        rows.add('r|$id');
        return rows;
      },
    );
    if (!wrote) throw StateError('Could not persist explicit watchlist re-add');
  }

  static Future<void> _acknowledge(String id, int bit, int at) async {
    final prefs = await ProfilePreferences.instance();
    await prefs.mutateStringListAtomically(_completionJournalKey, (old) {
      final rows = [...?old];
      for (var i = 0; i < rows.length; i++) {
        final entry = CompletedMovieWatchlistIntent.decode(rows[i]);
        if (entry?.imdbId != id || entry!.startedAtMs != at) continue;
        final remaining = entry.pending & ~bit;
        if (remaining == 0) {
          rows.removeAt(i);
        } else {
          rows[i] = CompletedMovieWatchlistIntent(id, at, remaining).encode();
        }
        break;
      }
      return rows;
    });
  }

  /// Read-only local journal probe used before scheduling a replay at the next
  /// authenticated playback launch. No network request is made by this read.
  static Future<Set<String>> pendingCompletedMovieIds() async => {
    for (final line in await _journal())
      if (CompletedMovieWatchlistIntent.decode(line) case final entry?)
        if (entry.pending != 0) entry.imdbId,
  };

  static Future<void> retryPendingCompletedMovies() async {
    final scope = ProfileRuntime.scope.value;
    for (final line in await _journal()) {
      if (scope != ProfileRuntime.scope.value) return;
      final entry = CompletedMovieWatchlistIntent.decode(line);
      if (entry == null || entry.pending == 0) continue;
      // Do not delete the intent while a just-started completion has queued
      // it but has not yet written the local finished record. An interrupted
      // rewatch leaves it inert until another completion replaces the entry.
      if (!await StorageService.isMovieFinished(entry.imdbId)) continue;
      await removeCompletedMovieEverywhere(entry.imdbId);
    }
  }

  /// Awaited by the playback path: the local My Watchlist shelf must update
  /// in the same transaction window as the watched badge and CW removal.
  static Future<void> removeCompletedMovieLocally(String movieId) async {
    final id = _id(movieId);
    if (id.isEmpty) return;
    final scope = ProfileRuntime.scope.value;
    final local = await StorageService.getMyWatchlistItems();
    if (scope != ProfileRuntime.scope.value) return;
    for (final item in local) {
      if (item.type != 'movie' || _id(item.effectiveImdbId ?? item.id) != id) {
        continue;
      }
      await _localWatchlistWriteLock.synchronized(() async {
        if (scope != ProfileRuntime.scope.value || await _readded(id)) return;
        if (scope != null) {
          await ProfileRuntime.withCapturedScope(
            scope,
            () => StorageService.setMyWatchlistItem(item, false),
          );
        } else {
          await StorageService.setMyWatchlistItem(item, false);
        }
      });
    }
  }

  /// Completion is a stronger, one-way intent than ordinary three-way list
  /// reconciliation. Delete a *movie* from every writable Watchlist owner;
  /// never touch watched history, a series queue, or Simkl's Watching/Completed
  /// buckets. A disconnected provider is retried by the next unified sync.
  /// Independent services are attempted concurrently after the local write:
  /// a slow Trakt response must not prevent Simkl and MDBList cleanup.
  static Future<void> removeCompletedMovieEverywhere(String movieId) async {
    final imdbId = _id(movieId);
    if (imdbId.isEmpty) return;
    final scope = ProfileRuntime.scope.value;
    // All writes below belong to the same completion generation. A deliberate
    // fresh re-add cancels an outstanding cleanup and must never be clobbered.
    final pending = await _pending(imdbId);
    if (scope != ProfileRuntime.scope.value ||
        (MediaIdentity.isImdb(imdbId) && pending == null)) {
      return;
    }
    await removeCompletedMovieLocally(imdbId);
    if (!MediaIdentity.isImdb(imdbId)) return;
    if (scope != ProfileRuntime.scope.value) return;
    await Future.wait<void>([
      for (final (bit, authenticated, remove)
          in <(int, Future<bool> Function(), Future<bool> Function(String))>[
            (_trakt, _gateway.traktAuthenticated, _gateway.removeFromTrakt),
            (
              _mdblist,
              _gateway.mdblistAuthenticated,
              _gateway.removeFromMdblist,
            ),
          ])
        () async {
          if ((pending!.pending & bit) == 0) return;
          try {
            if (!await authenticated() ||
                scope != ProfileRuntime.scope.value ||
                (await _pending(imdbId))?.startedAtMs != pending.startedAtMs ||
                !await StorageService.isMovieFinished(imdbId)) {
              return;
            }
            final removed = scope == null
                ? await remove(imdbId)
                : await ProfileRuntime.withCapturedScope(
                    scope,
                    () => remove(imdbId),
                  );
            if (removed && scope == ProfileRuntime.scope.value) {
              await _acknowledge(imdbId, bit, pending.startedAtMs);
            }
          } catch (e) {
            debugPrint('Watchlist completion retry: ${e.runtimeType}');
          }
        }(),
      () async {
        if ((pending!.pending & _simkl) == 0) return;
        try {
          if (!await _gateway.simklAuthenticated() ||
              scope != ProfileRuntime.scope.value) {
            return;
          }
          final status = await _gateway.simklStatus(imdbId);
          if (scope != ProfileRuntime.scope.value ||
              (await _pending(imdbId))?.startedAtMs != pending.startedAtMs ||
              !await StorageService.isMovieFinished(imdbId)) {
            return;
          }
          if (!status.readable) {
            // A failed status read must never masquerade as an empty library.
            return;
          }
          final moved =
              status.status != 'plantowatch' ||
              (scope == null
                  ? await _gateway.moveSimklToCompleted(imdbId)
                  : await ProfileRuntime.withCapturedScope(
                      scope,
                      () => _gateway.moveSimklToCompleted(imdbId),
                    ));
          if (moved && scope == ProfileRuntime.scope.value) {
            await _acknowledge(imdbId, _simkl, pending.startedAtMs);
          }
        } catch (e) {
          debugPrint('Simkl completion retry: ${e.runtimeType}');
        }
      }(),
    ]);
  }

  /// The one user-initiated My Watchlist write path.  Local state stays
  /// available immediately and, when unified tracking is enabled, the same
  /// intent is sent to both connected trackers instead of waiting for the
  /// next background reconciliation.
  static Future<void> setMyWatchlistItem(StremioMeta item, bool saved) async {
    final scope = ProfileRuntime.scope.value;
    await _localWatchlistWriteLock.synchronized(() async {
      final id = _id(item.effectiveImdbId ?? item.id);
      if (scope != ProfileRuntime.scope.value) return;
      if (saved &&
          item.type == 'movie' &&
          (await StorageService.isMovieFinished(id) ||
              await _pending(id) != null)) {
        await _explicitlyReadded(id);
      }
      if (scope != ProfileRuntime.scope.value) return;
      await StorageService.setMyWatchlistItem(item, saved);
    });
    if (scope != ProfileRuntime.scope.value) return;
    if (!await StorageService.getSyncAllContinueWatching() ||
        scope != ProfileRuntime.scope.value) {
      return;
    }
    final key = _key(item);
    if (key == null) return; // Trackers cannot address addon-local titles.
    final imdbId = item.effectiveImdbId!;
    final type = item.type;
    await Future.wait([
      _writeTrakt(imdbId, type, saved),
      _writeSimkl(imdbId, type, saved),
    ]);
  }

  static Future<void> _writeTrakt(
    String imdbId,
    String type,
    bool saved,
  ) async {
    if (!await TraktService.instance.isAuthenticated()) return;
    await _safe(
      () => saved
          ? TraktService.instance.addToWatchlist(imdbId, type)
          : TraktService.instance.removeFromWatchlist(imdbId, type),
    );
  }

  static Future<void> _writeSimkl(
    String imdbId,
    String type,
    bool saved,
  ) async {
    if (!await SimklService.instance.isAuthenticated()) return;
    final status = await SimklService.instance.fetchTitleStatus(
      imdbId,
      contentType: type,
    );
    if (status == null) return; // Never guess after a failed status read.
    if (saved && status.currentStatus == null) {
      await _safe(
        () => SimklService.instance.addToList(imdbId, type, 'plantowatch'),
      );
    } else if (!saved && status.currentStatus == 'plantowatch') {
      // Simkl has no watchlist-only DELETE: removeFromList destroys watched
      // history. 'hold' is the only non-watchlist bucket that preserves it.
      await _safe(() => SimklService.instance.addToList(imdbId, type, 'hold'));
    }
  }

  static Future<WatchlistSyncResult> sync() async {
    final scope = ProfileRuntime.scope.value;
    await retryPendingCompletedMovies();
    if (scope != ProfileRuntime.scope.value) return const WatchlistSyncResult();
    final traktAuthed = await TraktService.instance.isAuthenticated();
    final simklAuthed = await SimklService.instance.isAuthenticated();
    if (scope != ProfileRuntime.scope.value) return const WatchlistSyncResult();
    final results = await Future.wait<Object?>([
      StorageService.getMyWatchlistItems(),
      traktAuthed
          ? TraktListSource.instance.loadList(
              const TraktListChoice.builtin(TraktSeeAllList.watchlist),
            )
          : Future.value(null),
      simklAuthed
          ? SimklService.instance.fetchLibrarySnapshotOrNull()
          : Future.value(null),
    ]);
    if (scope != ProfileRuntime.scope.value) return const WatchlistSyncResult();

    final local = <String, StremioMeta>{};
    for (final item in results[0] as List<StremioMeta>) {
      final key = _key(item);
      if (key != null) local[key] = item;
    }

    final traktResult = results[1] as ({List<StremioMeta> items, bool failed})?;
    final traktReadable = traktResult != null && !traktResult.failed;
    final trakt = <String, StremioMeta>{};
    if (traktReadable) {
      for (final item in traktResult.items) {
        final key = _key(item);
        if (key != null) trakt[key] = item;
      }
    }

    final simklLibrary = results[2] as Map<String, dynamic>?;
    final simklReadable = simklAuthed && simklLibrary != null;
    final simkl = <String, StremioMeta>{};
    final simklStatus = <String, String>{};
    if (simklReadable) {
      for (final bucket in const ['movies', 'shows', 'anime']) {
        final list = simklLibrary[bucket];
        if (list is! List) continue;
        for (final raw in list) {
          if (raw is! Map<String, dynamic>) continue;
          final meta = SimklItemTransformer.transformItem(raw);
          if (meta == null) continue;
          final key = _key(meta);
          final status = raw['status'];
          if (key == null || status is! String) continue;
          simklStatus[key] = status;
          if (status == 'plantowatch') simkl[key] = meta;
        }
      }
    }

    // Titles being watched: starting playback takes a title off My Watchlist,
    // and Simkl may not have moved it to Watching yet — its Simkl entry must
    // not be removed (removal is whole-title and would wipe the new session).
    final watching = {
      for (final item in await StorageService.getContinueWatchingItems())
        (item['imdbId'] as String? ?? '').trim().toLowerCase(),
    };
    final previous = await StorageService.getWatchlistSyncSnapshot();
    // An already completed movie must not be re-imported from a stale cloud
    // watchlist by a later three-way reconciliation pass.
    final finishedMovies = await StorageService.getFinishedMovieIds();
    final union = <String, StremioMeta>{...simkl, ...trakt, ...local};
    final agreed = <String>{};
    var added = 0, removed = 0;

    for (final MapEntry(key: key, value: fallbackMeta) in union.entries) {
      if (scope != ProfileRuntime.scope.value) {
        return const WatchlistSyncResult();
      }
      // All three list APIs expose their list-added time.  Preserve the first
      // known addition as the canonical sort key, even if another service was
      // connected later and only just received the title.
      final meta = _oldestAdded(
        [local[key], trakt[key], simkl[key]].whereType<StremioMeta>(),
        fallbackMeta,
      );
      final imdbId = meta.effectiveImdbId!;
      final type = meta.type;
      final inLocal = local.containsKey(key);
      final inTrakt = trakt.containsKey(key);
      // Simkl: Plan to Watch = has it; not in the library = can add it; any
      // other status (watching, completed, …) = sits this title out.
      final simklHas = simkl.containsKey(key);
      final simklCanAdd = simklReadable && simklStatus[key] == null;

      final manuallyReadded = type == 'movie' && await _readded(imdbId);
      final finishedNow =
          type == 'movie' &&
          !manuallyReadded &&
          (finishedMovies.contains(_id(imdbId)) ||
              await StorageService.isMovieFinished(imdbId));
      if (finishedNow) {
        // Older completed titles did not have a retry journal. Adopt them only
        // when an actual watchlist still contains the finished title.
        if (await _pending(imdbId) == null &&
            (inLocal || inTrakt || simklHas)) {
          await queueCompletedMovieRemoval(imdbId);
        }
        await removeCompletedMovieEverywhere(imdbId);
        if (inLocal) removed++;
        // A remote outage must not make a finished item eligible to be
        // re-added as soon as that provider reconnects.
        continue;
      }

      final wasAgreed = !manuallyReadded && (previous?.contains(key) ?? false);
      final missingSomewhere =
          !inLocal || (traktReadable && !inTrakt) || simklCanAdd;

      if (wasAgreed && missingSomewhere) {
        // Removed on one list since the last sync — remove it everywhere.
        if (inLocal) {
          await StorageService.setMyWatchlistItem(local[key]!, false);
          removed++;
        }
        if (traktReadable && inTrakt) {
          if (await _safe(
            () => TraktService.instance.removeFromWatchlist(imdbId, type),
          )) {
            removed++;
          }
        }
        if (simklHas && !watching.contains(imdbId.toLowerCase())) {
          if (await _safe(
            () => SimklService.instance.addToList(imdbId, type, 'hold'),
          )) {
            removed++;
          }
        }
        continue;
      }

      var allAdded = true;
      if (!inLocal) {
        await StorageService.setMyWatchlistItem(
          meta,
          true,
          addedAtMs: meta.addedAtMs,
        );
        added++;
      }
      if (traktReadable && !inTrakt) {
        if (await _safe(
          () => TraktService.instance.addToWatchlist(imdbId, type),
        )) {
          added++;
        } else {
          allAdded = false;
        }
      }
      if (simklCanAdd) {
        if (await _safe(
          () => SimklService.instance.addToList(imdbId, type, 'plantowatch'),
        )) {
          added++;
        } else {
          allAdded = false;
        }
      }
      if (allAdded) agreed.add(key);
    }

    // A title agreed last time that no readable list has now may still sit on
    // an unreadable one; keep it so its removal propagates once that list is
    // back instead of the title being re-added everywhere.
    if (previous != null && (!traktReadable || !simklReadable)) {
      for (final key in previous) {
        if (!union.containsKey(key)) agreed.add(key);
      }
    }
    if (scope != ProfileRuntime.scope.value) return const WatchlistSyncResult();
    await StorageService.setWatchlistSyncSnapshot(agreed);
    return WatchlistSyncResult(added: added, removed: removed);
  }

  /// `type|imdb` for movies and series with an IMDb id; other titles (addon
  /// or native ids) stay local-only because the trackers can't address them.
  static String? _key(StremioMeta item) {
    final type = item.type.trim().toLowerCase();
    if (type != 'movie' && type != 'series') return null;
    final imdb = item.effectiveImdbId?.trim().toLowerCase();
    if (imdb == null || !imdb.startsWith('tt')) return null;
    return '$type|$imdb';
  }

  static Future<bool> _safe(Future<bool> Function() call) async {
    try {
      return await call();
    } catch (e) {
      debugPrint('WatchlistSync: $e');
      return false;
    }
  }

  static StremioMeta _oldestAdded(
    Iterable<StremioMeta> items,
    StremioMeta fallback,
  ) {
    StremioMeta? oldest;
    for (final item in items) {
      final stamp = item.addedAtMs;
      if (stamp == null || stamp <= 0) continue;
      if (oldest == null || stamp < oldest.addedAtMs!) oldest = item;
    }
    return oldest ?? fallback;
  }
}

class WatchlistSyncResult {
  final int added;
  final int removed;
  const WatchlistSyncResult({this.added = 0, this.removed = 0});
  int get total => added + removed;
}
