import 'package:flutter/foundation.dart';

import '../models/stremio_addon.dart';
import 'simkl/simkl_item_transformer.dart';
import 'simkl/simkl_service.dart';
import 'storage_service.dart';
import 'trakt/trakt_list_source.dart';
import 'trakt/trakt_service.dart';

/// Keeps Debrify's My Watchlist, the Trakt watchlist and Simkl's Plan to
/// Watch in step while "Sync Continue Watching everywhere" is on.
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

  static Future<WatchlistSyncResult> sync() async {
    final traktAuthed = await TraktService.instance.isAuthenticated();
    final simklAuthed = await SimklService.instance.isAuthenticated();
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

    final local = <String, StremioMeta>{};
    for (final item in results[0] as List<StremioMeta>) {
      final key = _key(item);
      if (key != null) local[key] = item;
    }

    final traktResult =
        results[1] as ({List<StremioMeta> items, bool failed})?;
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
    final union = <String, StremioMeta>{...simkl, ...trakt, ...local};
    final agreed = <String>{};
    var added = 0, removed = 0;

    for (final MapEntry(key: key, value: meta) in union.entries) {
      final imdbId = meta.effectiveImdbId!;
      final type = meta.type;
      final inLocal = local.containsKey(key);
      final inTrakt = trakt.containsKey(key);
      // Simkl: Plan to Watch = has it; not in the library = can add it; any
      // other status (watching, completed, …) = sits this title out.
      final simklHas = simkl.containsKey(key);
      final simklCanAdd = simklReadable && simklStatus[key] == null;

      final wasAgreed = previous?.contains(key) ?? false;
      final missingSomewhere =
          !inLocal || (traktReadable && !inTrakt) || simklCanAdd;

      if (wasAgreed && missingSomewhere) {
        // Removed on one list since the last sync — remove it everywhere.
        if (inLocal) {
          await StorageService.setMyWatchlistItem(local[key]!, false);
          removed++;
        }
        if (traktReadable && inTrakt) {
          if (await _safe(() => TraktService.instance.removeFromWatchlist(imdbId, type))) {
            removed++;
          }
        }
        if (simklHas && !watching.contains(imdbId.toLowerCase())) {
          if (await _safe(() => SimklService.instance.removeFromList(imdbId, type))) {
            removed++;
          }
        }
        continue;
      }

      if (!inLocal) {
        await StorageService.setMyWatchlistItem(meta, true);
        added++;
      }
      if (traktReadable && !inTrakt) {
        if (await _safe(() => TraktService.instance.addToWatchlist(imdbId, type))) {
          added++;
        }
      }
      if (simklCanAdd) {
        if (await _safe(() => SimklService.instance.addToList(imdbId, type, 'plantowatch'))) {
          added++;
        }
      }
      agreed.add(key);
    }

    // A title agreed last time that no readable list has now may still sit on
    // an unreadable one; keep it so its removal propagates once that list is
    // back instead of the title being re-added everywhere.
    if (previous != null && (!traktReadable || !simklReadable)) {
      for (final key in previous) {
        if (!union.containsKey(key)) agreed.add(key);
      }
    }
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
}

class WatchlistSyncResult {
  final int added;
  final int removed;
  const WatchlistSyncResult({this.added = 0, this.removed = 0});
  int get total => added + removed;
}
