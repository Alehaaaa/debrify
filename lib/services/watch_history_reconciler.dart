/// A completed movie, whole-show action, or individual episode. Resume points
/// are deliberately handled separately from completion evidence.
class WatchHistoryRecord {
  const WatchHistoryRecord(
    this.id,
    this.type, {
    this.season,
    this.episode,
    this.at,
  });
  final String id, type;
  final int? season, episode, at;
  String get key => '$type|$id|${season ?? ''}|${episode ?? ''}';
  Map<String, dynamic> toJson() => {
    'id': id,
    'type': type,
    'season': season,
    'episode': episode,
    'at': at,
  };
  factory WatchHistoryRecord.fromJson(Map<String, dynamic> value) =>
      WatchHistoryRecord(
        value['id'] as String,
        value['type'] as String,
        season: value['season'] as int?,
        episode: value['episode'] as int?,
        at: value['at'] as int?,
      );
}

class WatchHistoryOwner {
  WatchHistoryOwner({
    required this.id,
    required this.read,
    required this.write,
    this.supports,
    this.readsWholeShows = true,
  });
  final String id;
  final bool readsWholeShows;
  final Future<List<WatchHistoryRecord>?> Function() read;
  final Future<bool> Function(WatchHistoryRecord record, bool watched) write;
  final bool Function(WatchHistoryRecord record)? supports;
}

class WatchHistorySyncResult {
  const WatchHistorySyncResult({this.changed = 0, this.failed = 0});
  final int changed, failed;
}

/// Three-way reconciliation. Only a disappearance from an owner's previously
/// observed history means removal. A newly connected empty owner gets backfill.
/// Failed reads never mean empty; failed deletions remain durable for retry.
class WatchHistoryReconciler {
  static Future<WatchHistorySyncResult> run({
    required List<WatchHistoryOwner> owners,
    required Map<String, dynamic> state,
    required Future<bool> Function() current,
    required Future<void> Function(Map<String, dynamic>) checkpoint,
  }) async {
    final baseline = Map<String, dynamic>.from(state['owners'] as Map? ?? {});
    final pending = Map<String, dynamic>.from(state['removed'] as Map? ?? {});
    final snapshots = <String, Map<String, WatchHistoryRecord>>{};
    var failed = 0, changed = 0;
    for (final owner in owners) {
      if (!await current()) {
        return WatchHistorySyncResult(changed: changed, failed: failed + 1);
      }
      try {
        final rows = await owner.read();
        if (rows == null) {
          failed++;
          continue;
        }
        final snapshot = {for (final row in rows) row.key: row};
        // Trakt and Simkl expand whole-show actions into individual episodes.
        // Keep the action receipt; absence of a synthetic show row isn't unwatch.
        if (!owner.readsWholeShows) {
          for (final raw in (baseline[owner.id] as Map? ?? {}).values) {
            final row = WatchHistoryRecord.fromJson(
              Map<String, dynamic>.from(raw as Map),
            );
            if (row.type == 'series' && row.episode == null) {
              snapshot[row.key] = row;
            }
          }
        }
        snapshots[owner.id] = snapshot;
      } catch (_) {
        failed++;
      }
    }
    if (!await current()) {
      return WatchHistorySyncResult(changed: changed, failed: failed + 1);
    }
    final merged = <String, WatchHistoryRecord>{};
    for (final snapshot in snapshots.values) {
      for (final row in snapshot.values) {
        if ((row.at ?? 0) >= (merged[row.key]?.at ?? 0)) merged[row.key] = row;
      }
    }
    // A new explicit local watch can supersede an older removal. Keep other
    // tombstones, including across disconnected accounts, until then.
    final oldLocal = baseline['local'] as Map?;
    if (oldLocal != null) {
      for (final row in snapshots['local']?.values ?? <WatchHistoryRecord>[]) {
        if (!oldLocal.containsKey(row.key)) pending.remove(row.key);
      }
    }
    for (final entry in snapshots.entries) {
      final previous = baseline[entry.key] as Map? ?? {};
      for (final key in previous.keys) {
        final row = WatchHistoryRecord.fromJson(
          Map<String, dynamic>.from(previous[key] as Map),
        );
        final owner = owners.firstWhere((owner) => owner.id == entry.key);
        if (!entry.value.containsKey(key) &&
            owner.supports?.call(row) != false) {
          pending[key as String] = previous[key];
        }
      }
    }
    // Unwatching an entire show also clears individual episode evidence.
    final removedShows = pending.values
        .map(
          (v) =>
              WatchHistoryRecord.fromJson(Map<String, dynamic>.from(v as Map)),
        )
        .where((r) => r.type == 'series' && r.episode == null)
        .map((r) => r.id)
        .toSet();
    for (final row in merged.values) {
      if (row.type == 'series' && removedShows.contains(row.id)) {
        pending[row.key] = row.toJson();
      }
    }
    // Save intent before side effects; a crash cannot turn a partially applied
    // removal into a newly discovered watched item on the next run.
    await checkpoint({'owners': baseline, 'removed': pending});
    for (final owner in owners) {
      final snapshot = snapshots[owner.id];
      if (snapshot == null) continue;
      final desired = <String, WatchHistoryRecord>{...merged};
      for (final raw in pending.values) {
        final row = WatchHistoryRecord.fromJson(
          Map<String, dynamic>.from(raw as Map),
        );
        desired[row.key] = row;
      }
      for (final row in desired.values) {
        final watched = !pending.containsKey(row.key);
        if (snapshot.containsKey(row.key) == watched ||
            owner.supports?.call(row) == false) {
          continue;
        }
        if (!await current()) {
          return WatchHistorySyncResult(changed: changed, failed: failed + 1);
        }
        try {
          if (await owner.write(row, watched)) {
            watched ? snapshot[row.key] = row : snapshot.remove(row.key);
            changed++;
          } else {
            failed++;
          }
        } catch (_) {
          failed++;
        }
      }
      baseline[owner.id] = {
        for (final row in snapshot.values) row.key: row.toJson(),
      };
      if (!await current()) {
        return WatchHistorySyncResult(changed: changed, failed: failed + 1);
      }
      await checkpoint({'owners': baseline, 'removed': pending});
    }

    if (await current()) {
      await checkpoint({'owners': baseline, 'removed': pending});
    }
    return WatchHistorySyncResult(changed: changed, failed: failed);
  }
}
