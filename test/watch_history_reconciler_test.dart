import 'dart:convert';
import 'package:debrify/services/watch_history_reconciler.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const movie = WatchHistoryRecord('tt1234567', 'movie', at: 1000);
  const episode = WatchHistoryRecord(
    'tt7654321',
    'series',
    season: 0,
    episode: 1,
    at: 2000,
  );
  late Map<String, dynamic> state;
  late Map<String, List<WatchHistoryRecord>?> data;
  late Set<String> failingWrites;
  late List<String> writes;
  late bool current;
  Future<WatchHistorySyncResult> run({
    List<String>? names,
    Set<String> expanded = const {},
  }) => WatchHistoryReconciler.run(
    owners: [
      for (final name in names ?? data.keys.toList())
        WatchHistoryOwner(
          id: name,
          readsWholeShows: !expanded.contains(name),
          read: () async => data[name],
          write: (r, watched) async {
            writes.add('$name:${r.key}:$watched');
            if (failingWrites.contains(name)) return false;
            final records = data[name]!;
            records.removeWhere((v) => v.key == r.key);
            if (watched) records.add(r);
            return true;
          },
        ),
    ],
    state: state,
    current: () async => current,
    checkpoint: (value) async {
      state = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
    },
  );
  setUp(() {
    state = {};
    data = {'local': [], 'trakt': [], 'simkl': []};
    failingWrites = {};
    writes = [];
    current = true;
  });
  test(
    'first sync merges old movies and specials in both directions',
    () async {
      data['local'] = [movie];
      data['trakt'] = [episode];
      expect((await run()).changed, 4);
      for (final rows in data.values) {
        expect(rows!.map((r) => r.key), containsAll([movie.key, episode.key]));
        expect(rows.singleWhere((r) => r.key == episode.key).at, 2000);
      }
      writes.clear();
      expect((await run()).changed, 0);
      expect(writes, isEmpty);
    },
  );
  test('new empty owner is backfilled, never interpreted as removal', () async {
    data['local'] = [movie];
    await run(names: ['local', 'trakt']);
    await run();
    expect(data['simkl']!.single.key, movie.key);
  });
  test('failed reads do not clear history and recover next time', () async {
    data['local'] = [movie];
    await run();
    data['trakt'] = null;
    expect((await run()).failed, 1);
    expect(data['local'], hasLength(1));
    expect(data['simkl'], hasLength(1));
    data['trakt'] = [movie];
    expect((await run()).changed, 0);
  });
  test(
    'failed additions remain retryable rather than becoming removals',
    () async {
      data['local'] = [movie];
      failingWrites.add('trakt');
      expect((await run()).failed, 1);
      failingWrites.clear();
      expect((await run()).changed, 1);
      expect(data['local'], hasLength(1));
      expect(data['trakt'], hasLength(1));
    },
  );
  test('unwatch propagates and failed removals survive a restart', () async {
    data['local'] = [movie];
    await run();
    data['local']!.clear();
    failingWrites.add('trakt');
    expect((await run()).failed, greaterThan(0));
    expect(data['simkl'], isEmpty);
    expect(state['removed'], contains(movie.key));
    failingWrites.clear();
    await run();
    expect(data['trakt'], isEmpty);
    expect(data['local'], isEmpty);
  });
  test(
    'disconnected owner cannot resurrect a removed movie on reconnect',
    () async {
      data['local'] = [movie];
      await run();
      data['local']!.clear();
      await run(names: ['local', 'simkl']);
      await run();
      expect(data.values.every((rows) => rows!.isEmpty), true);
    },
  );
  test('new explicit watch overrides an older removal', () async {
    data['local'] = [movie];
    await run();
    data['local']!.clear();
    await run();
    data['local'] = [movie];
    await run();
    expect(data.values.every((rows) => rows!.length == 1), true);
  });
  test('expanded whole-show acknowledgements do not infer unwatch', () async {
    const show = WatchHistoryRecord('tt7654321', 'series');
    data['local'] = [show];
    await run(expanded: {'trakt', 'simkl'});
    data['trakt'] = [episode];
    data['simkl'] = [episode];
    writes.clear();
    await run(expanded: {'trakt', 'simkl'});
    expect(writes.every((w) => w.endsWith(':true')), true);
    expect(data['local']!.map((r) => r.key), contains(show.key));
  });
  test('whole-show removal also clears old episode evidence', () async {
    const show = WatchHistoryRecord('tt7654321', 'series');
    data['local'] = [show, episode];
    await run();
    data['local']!.clear();
    await run();
    expect(data.values.every((rows) => rows!.isEmpty), true);
  });
  test(
    'profile change during read prevents every write and checkpoint',
    () async {
      final result = await WatchHistoryReconciler.run(
        owners: [
          WatchHistoryOwner(
            id: 'local',
            read: () async {
              current = false;
              return [movie];
            },
            write: (_, _) async {
              fail('stale profile write');
            },
          ),
        ],
        state: {},
        current: () async => current,
        checkpoint: (_) async {
          fail('stale profile checkpoint');
        },
      );
      expect(result.changed, 0);
    },
  );
  test(
    'removed server library items do not become unwatched elsewhere',
    () async {
      data['local'] = [movie];
      await run(names: ['local', 'trakt']);
      await WatchHistoryReconciler.run(
        owners: [
          WatchHistoryOwner(
            id: 'local',
            read: () async => [movie],
            write: (_, _) async {
              fail('unexpected unwatch');
            },
          ),
          WatchHistoryOwner(
            id: 'trakt',
            read: () async => [],
            supports: (_) => false,
            write: (_, _) async {
              fail('unavailable item');
            },
          ),
        ],
        state: state,
        current: () async => true,
        checkpoint: (_) async {},
      );
    },
  );
}
