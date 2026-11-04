import 'dart:async';
import 'dart:math';

import 'package:debrify/services/reels_feed.dart';
import 'package:flutter_test/flutter_test.dart';

import 'reels_test.dart' show FakeTmdb;

void main() {
  test('ready scenes do not wait on a slow unrelated confirmation', () async {
    ReelsFeed.resetSession();
    final tmdb = FakeTmdb();
    final slow = Completer<void>();
    var confirmations = 0;
    final feed = ReelsFeed(
      configured: true,
      language: 'en-US',
      random: Random(1),
      get: (path, query) async {
        if (!path.endsWith('/popular') && ++confirmations == 1) {
          await slow.future;
        }
        return tmdb.get(path, query);
      },
    );
    try {
      final first = await feed.take(1).timeout(const Duration(seconds: 2));
      expect(first, hasLength(1));
      expect(slow.isCompleted, isFalse);
      final queued = await feed.take(6).timeout(const Duration(seconds: 2));
      expect(queued, hasLength(6));
      expect(confirmations, 8);
      expect(feed.exhausted, isFalse);
      slow.complete();
      final last = await feed.take(1);
      expect(last, hasLength(1));
      expect(
        {...first, ...queued, ...last}.map((r) => r.item.id).toSet(),
        hasLength(8),
      );
    } finally {
      if (!slow.isCompleted) slow.complete();
    }
  });
}
