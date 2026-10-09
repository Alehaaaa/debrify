import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../models/media_identity.dart';
import '../models/media_server.dart';
import 'media_server_service.dart';
import 'media_server_watch_sync.dart';
import 'mdblist/mdblist_models.dart';
import 'mdblist/mdblist_service.dart';
import 'profiles/profile_preferences.dart';
import 'profiles/profile_runtime.dart';
import 'profiles/profile_credential_facade.dart';
import 'simkl/simkl_service.dart';
import 'storage_service.dart';
import 'trakt/trakt_service.dart';
import 'watch_history_reconciler.dart';

class WatchHistorySyncService {
  static const _key = 'watch_history_reconciliation_v1';

  static Future<WatchHistorySyncResult> sync() async {
    final scope = ProfileRuntime.scope.value;
    final prefs = await ProfilePreferences.instance();
    final settingsRevision = StorageService.trackingSourceRevision.value;
    var localRevision = StorageService.localCompletionRevision.value;
    final authorizations = <Future<bool> Function()>[];
    Future<bool> baseCurrent() async =>
        scope == ProfileRuntime.scope.value &&
        settingsRevision == StorageService.trackingSourceRevision.value &&
        localRevision == StorageService.localCompletionRevision.value &&
        await StorageService.getSyncAllContinueWatching();
    Future<bool> current() async {
      if (!await baseCurrent()) return false;
      for (final authorize in authorizations) {
        if (!await authorize()) return false;
      }
      return true;
    }

    if (!await current()) return const WatchHistorySyncResult();
    final owners = <WatchHistoryOwner>[
      WatchHistoryOwner(
        id: 'local',
        read: _local,
        write: (r, watched) async {
          if (!await current()) return false;
          final result = await _writeLocal(r, watched);
          localRevision = StorageService.localCompletionRevision.value;
          return result;
        },
      ),
    ];
    Future<void> add(
      String name,
      String credential,
      Future<String?> Function() token,
      Future<List<WatchHistoryRecord>?> Function() read,
      Future<bool> Function(WatchHistoryRecord, bool) write,
    ) async {
      final secret = await token();
      if (secret == null || secret.isEmpty) return;
      final authority = await ProfileCredentialFacade.boundAuthority(
        credential,
      );
      final identity = authority == null
          ? sha256.convert(utf8.encode(secret)).toString()
          : '${authority.resourceId}:${authority.resourceAuthorizationRevision}';
      Future<bool> authorized() async {
        if (!await baseCurrent()) return false;
        if (authority != null) {
          return await ProfileCredentialFacade.boundAuthority(credential) ==
              authority;
        }
        return await token() == secret;
      }

      authorizations.add(authorized);
      owners.add(
        WatchHistoryOwner(
          id: '$name:$identity',
          readsWholeShows: name == 'mdblist',
          read: () async => await authorized() ? read() : null,
          write: (row, watched) async =>
              await authorized() && await write(row, watched),
        ),
      );
    }

    await add(
      'trakt',
      'trakt_access_token',
      StorageService.getTraktAccessToken,
      _trakt,
      (r, watched) => r.episode != null
          ? watched
                ? TraktService.instance.markEpisodeWatched(
                    r.id,
                    r.season!,
                    r.episode!,
                    watchedAt: _date(r.at),
                  )
                : TraktService.instance.markEpisodeUnwatched(
                    r.id,
                    r.season!,
                    r.episode!,
                  )
          : watched
          ? TraktService.instance.addToHistory(
              r.id,
              r.type,
              watchedAt: _date(r.at),
            )
          : TraktService.instance.removeFromHistory(r.id, r.type),
    );
    await add(
      'simkl',
      'simkl_access_token',
      StorageService.getSimklAccessToken,
      _simkl,
      (r, watched) => r.episode != null
          ? watched
                ? SimklService.instance.markEpisodeWatched(
                    r.id,
                    r.season!,
                    r.episode!,
                    watchedAt: _date(r.at),
                  )
                : SimklService.instance.markEpisodeUnwatched(
                    r.id,
                    r.season!,
                    r.episode!,
                  )
          : watched
          ? SimklService.instance.markWatched(
              r.id,
              r.type,
              watchedAt: _date(r.at),
            )
          : SimklService.instance.markUnwatched(r.id, r.type),
    );
    await add(
      'mdblist',
      'mdblist_api_key',
      StorageService.getMdblistApiKey,
      _mdblist,
      (r, watched) {
        final ids = MdblistMediaIds.forContent(r.id);
        final type = r.episode != null
            ? 'episode'
            : r.type == 'series'
            ? 'show'
            : 'movie';
        return watched
            ? MdblistService.instance.markWatched(
                ids,
                type,
                season: r.season,
                episode: r.episode,
                watchedAt: _date(r.at),
              )
            : MdblistService.instance.markUnwatched(
                ids,
                type,
                season: r.season,
                episode: r.episode,
              );
      },
    );
    if (await MediaServerWatchSync.enabled()) {
      for (final kind in MediaServerKind.values) {
        for (final resource in await MediaServerService.libraryConnections(
          kind,
        )) {
          final inventory = <String, List<String>>{};
          MediaServerLibrarySession? session;
          authorizations.add(() async {
            if (!await MediaServerWatchSync.enabled()) return false;
            try {
              await session?.authorize();
              return true;
            } catch (_) {
              return false;
            }
          });
          owners.add(
            WatchHistoryOwner(
              id: 'server:${resource.id}:${resource.authorizationRevision}',
              supports: (r) => inventory.containsKey(r.key),
              read: () async {
                session = await MediaServerService.openLibrary(resource.id);
                final seriesIds = <String, String?>{};
                final rows = <WatchHistoryRecord>[];
                int? offset = 0;
                while (offset != null) {
                  if (!await current() ||
                      !await MediaServerWatchSync.enabled()) {
                    return null;
                  }
                  final page = await session!.browse(
                    offset: offset,
                    mode: 'history',
                  );
                  for (final item in page.items) {
                    if (item.type != 'Movie' && !item.numberedEpisode) continue;
                    var data = item.data;
                    String? id;
                    if (item.numberedEpisode) {
                      if (!seriesIds.containsKey(item.seriesId)) {
                        data = (await session!.item(item.seriesId!)).data;
                        seriesIds[item.seriesId!] = _serverId(data);
                      }
                      id = seriesIds[item.seriesId];
                    } else {
                      id = _serverId(data);
                    }
                    if (id == null) continue;
                    final row = WatchHistoryRecord(
                      id,
                      item.numberedEpisode ? 'series' : 'movie',
                      season: item.numberedEpisode ? item.season : null,
                      episode: item.numberedEpisode ? item.episode : null,
                      at: _time(
                        (item.data['UserData'] as Map?)?['LastPlayedDate'],
                      ),
                    );
                    inventory.putIfAbsent(row.key, () => []).add(item.id);
                    if (item.watched) rows.add(row);
                  }
                  offset = page.nextOffset;
                }
                return rows;
              },
              write: (r, watched) async {
                if (!await current() || !await MediaServerWatchSync.enabled()) {
                  return false;
                }
                for (final id in inventory[r.key] ?? <String>[]) {
                  await session!.setHistoryWatched(
                    id,
                    watched,
                    at: r.at == null
                        ? null
                        : DateTime.fromMillisecondsSinceEpoch(
                            r.at!,
                            isUtc: true,
                          ),
                  );
                }
                return true;
              },
            ),
          );
        }
      }
    }
    Map<String, dynamic> state = {};
    try {
      state = jsonDecode(prefs.getString(_key) ?? '{}') as Map<String, dynamic>;
    } catch (_) {
      /* Older or corrupt checkpoints cause additive backfill. */
    }
    return WatchHistoryReconciler.run(
      owners: owners,
      state: state,
      current: current,
      checkpoint: (value) async {
        if (await current()) await prefs.setString(_key, jsonEncode(value));
      },
    );
  }

  static String? _serverId(Map<String, dynamic> data) {
    final ids = data['ProviderIds'];
    if (ids is! Map) return null;
    return MediaIdentity.preferred({
      for (final entry in ids.entries)
        entry.key.toString().toLowerCase(): entry.value,
    });
  }

  static bool _supported(String id) =>
      MediaIdentity.isImdb(id) || MediaIdentity.isNative(id);
  static DateTime? _date(int? at) => at == null || at <= 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(at, isUtc: true);
  static int? _time(dynamic value) => value is String
      ? DateTime.tryParse(value)?.millisecondsSinceEpoch
      : (value as num?)?.toInt();
  static String? _id(dynamic container) =>
      container is Map ? MediaIdentity.preferred(container['ids']) : null;

  static Future<List<WatchHistoryRecord>> _local() async => [
    for (final id in await StorageService.getFinishedMovieIds())
      if (_supported(id)) WatchHistoryRecord(id, 'movie'),
    for (final id in await StorageService.getExplicitlyWatchedSeriesIds())
      if (_supported(id)) WatchHistoryRecord(id, 'series'),
    for (final row in await StorageService.getCompletedEpisodeHistory())
      if (_supported(row['id'] as String))
        WatchHistoryRecord(
          row['id'] as String,
          'series',
          season: row['season'] as int,
          episode: row['episode'] as int,
          at: _time(row['at']),
        ),
  ];

  static Future<bool> _writeLocal(WatchHistoryRecord r, bool watched) async {
    if (r.episode != null) {
      if (watched) {
        await StorageService.markEpisodeAsFinished(
          seriesTitle: r.id,
          imdbId: r.id,
          season: r.season!,
          episode: r.episode!,
          recoveryUpdatedAtMs: r.at ?? 0,
        );
      } else {
        await StorageService.unmarkEpisodeAsFinished(
          seriesTitle: r.id,
          imdbId: r.id,
          season: r.season!,
          episode: r.episode!,
        );
      }
    } else if (r.type == 'movie') {
      if (watched) {
        await StorageService.markMovieAsFinished(r.id, preserveResume: true);
      } else {
        await StorageService.unmarkMovieAsFinished(r.id);
      }
    } else {
      await StorageService.setSeriesExplicitlyWatched(r.id, watched: watched);
    }
    return true;
  }

  static Future<List<WatchHistoryRecord>?> _trakt() async {
    final movies = await TraktService.instance.fetchWatchedHistoryRows(
      'movies',
    );
    final shows = await TraktService.instance.fetchWatchedHistoryRows('shows');
    if (movies == null || shows == null) return null;
    return parseTrakt(movies, shows);
  }

  static List<WatchHistoryRecord> parseTrakt(
    List<dynamic> movies,
    List<dynamic> shows,
  ) {
    final result = <WatchHistoryRecord>[];
    if (movies.any((r) => r is! Map) || shows.any((r) => r is! Map)) {
      throw const FormatException('Incomplete watched history');
    }
    for (final raw in movies.whereType<Map>()) {
      if (raw['movie'] is! Map) {
        throw const FormatException('Missing movie identity');
      }
      final id = _id(raw['movie']);
      if (id != null) {
        result.add(
          WatchHistoryRecord(id, 'movie', at: _time(raw['last_watched_at'])),
        );
      }
    }
    for (final raw in shows.whereType<Map>()) {
      if (raw['show'] is! Map || raw['seasons'] is! List) {
        throw const FormatException('Missing episode history');
      }
      final id = _id(raw['show']);
      if (id == null) continue;
      for (final season in (raw['seasons'] as List? ?? []).whereType<Map>()) {
        final sn = (season['number'] as num?)?.toInt();
        if (sn == null) continue;
        for (final episode
            in (season['episodes'] as List? ?? []).whereType<Map>()) {
          final ep = (episode['number'] as num?)?.toInt();
          if (ep != null) {
            result.add(
              WatchHistoryRecord(
                id,
                'series',
                season: sn,
                episode: ep,
                at: _time(episode['last_watched_at']),
              ),
            );
          }
        }
      }
    }
    return result;
  }

  static Future<List<WatchHistoryRecord>?> _simkl() async {
    final data = await SimklService.instance.fetchLibrarySnapshotOrNull();
    if (data == null) return null;
    final result = <WatchHistoryRecord>[];
    for (final bucket in ['movies', 'shows', 'anime']) {
      for (final raw in (data[bucket] as List? ?? []).whereType<Map>()) {
        final movie = raw['movie'];
        final id = _id(movie ?? raw['show']);
        if (id == null) continue;
        if (movie != null || bucket == 'movies') {
          if (raw['status'] == 'completed') {
            result.add(
              WatchHistoryRecord(
                id,
                'movie',
                at: _time(raw['last_watched_at']),
              ),
            );
          }
        } else {
          // Include partially watched and dropped shows, not only completed ones.
          final history = await SimklService.instance
              .fetchWatchedEpisodeHistory(id);
          if (history == null || history['seasons'] is! List) return null;
          for (final season in (history['seasons'] as List).whereType<Map>()) {
            final sn = (season['number'] as num?)?.toInt();
            if (sn == null || season['episodes'] is! List) return null;
            for (final ep in (season['episodes'] as List).whereType<Map>()) {
              if (ep['watched'] != true) continue;
              final en = (ep['number'] as num?)?.toInt();
              if (en == null) return null;
              result.add(
                WatchHistoryRecord(
                  id,
                  'series',
                  season: sn,
                  episode: en,
                  at: _time(ep['last_watched_at']),
                ),
              );
            }
          }
        }
      }
    }
    return result;
  }

  static Future<List<WatchHistoryRecord>?> _mdblist() async {
    final snapshot = await MdblistService.instance.fetchSyncSnapshot('watched');
    final episodes = await MdblistService.instance.fetchSyncSnapshot(
      'watched',
      mediaType: 'episode',
    );
    if (!snapshot.isSuccess || !episodes.isSuccess) return null;
    final result = <WatchHistoryRecord>[];
    for (final row in [...snapshot.data!, ...episodes.data!]) {
      final movie = _id(row['movie']);
      if (movie != null) {
        result.add(
          WatchHistoryRecord(movie, 'movie', at: _time(row['watched_at'])),
        );
      }
      final ep = row['episode'];
      final show = _id(ep is Map ? ep['show'] ?? row['show'] : row['show']);
      if (show == null) continue;
      if (ep is Map) {
        final sn =
            (ep['season'] ?? ep['season_num'] ?? ep['season_number']) as num?;
        final en =
            (ep['number'] ??
                    ep['episode_num'] ??
                    ep['episode'] ??
                    ep['episode_number'])
                as num?;
        if (sn != null && en != null) {
          result.add(
            WatchHistoryRecord(
              show,
              'series',
              season: sn.toInt(),
              episode: en.toInt(),
              at: _time(row['watched_at']),
            ),
          );
        }
      }
      // A watched show row is an explicit whole-show action.
      else {
        result.add(
          WatchHistoryRecord(show, 'series', at: _time(row['watched_at'])),
        );
      }
    }
    return result;
  }
}
