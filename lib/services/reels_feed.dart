import 'dart:math' as math;

import '../models/stremio_addon.dart';
import 'offline_title_store.dart';
import 'stremio_service.dart';

/// One catalog page of [type] ('movie' / 'series') from [skip].
typedef ReelsCatalogPage =
    Future<({List<StremioMeta> items, int rawCount})> Function(
      String type,
      int skip,
    );

/// The titles the Reels tab plays, one at a time.
///
/// Draws from the popular movie and series catalogs (the user's Cinemeta
/// install, else the stock one), alternating shows and films, each page
/// shuffled so the feed doesn't read as a ranked list. A title is handed out
/// once per app session — leaving the tab and coming back, or refreshing the
/// first reel, always brings something new. Titles without an IMDb id are
/// skipped: they have no trailer to find.
class ReelsFeed {
  ReelsFeed({ReelsCatalogPage? page, math.Random? random})
    : _page = page ?? _cinemetaTop,
      _random = random ?? math.Random();

  final ReelsCatalogPage _page;
  final math.Random _random;

  /// Session-wide, so a fresh feed (the tab remounts on every visit) never
  /// replays what this session already showed.
  static final Set<String> _shown = {};

  /// Test seam: forget what this session showed.
  static void resetSession() => _shown.clear();

  static const _types = ['series', 'movie'];
  final Map<String, List<StremioMeta>> _pool = {'series': [], 'movie': []};
  final Map<String, int> _skip = {'series': 0, 'movie': 0};
  final Set<String> _exhausted = {};
  int _turn = 0;

  /// The next title not yet shown this session, or null when every catalog
  /// has run dry.
  Future<StremioMeta?> next() async {
    for (var tries = 0; tries < _types.length * 4; tries++) {
      final type = _types[_turn++ % _types.length];
      if (_exhausted.contains(type)) continue;
      final pool = _pool[type]!;
      if (pool.isEmpty && !await _refill(type)) continue;
      while (pool.isNotEmpty) {
        final item = pool.removeLast();
        final id = item.effectiveImdbId;
        if (id == null || !_shown.add('$type:$id')) continue;
        return item;
      }
    }
    return null;
  }

  Future<bool> _refill(String type) async {
    try {
      final page = await _page(type, _skip[type]!);
      if (page.rawCount == 0) {
        _exhausted.add(type);
        return false;
      }
      _skip[type] = _skip[type]! + page.rawCount;
      _pool[type]!.addAll(page.items.toList()..shuffle(_random));
      return _pool[type]!.isNotEmpty;
    } catch (_) {
      // A failed page leaves this type out of the next turn, not the feed.
      return false;
    }
  }

  static Future<({List<StremioMeta> items, int rawCount})> _cinemetaTop(
    String type,
    int skip,
  ) async {
    final addon = await OfflineTitleStore.cinemetaAddon();
    var raw = 0;
    final items = await StremioService.instance.fetchCatalog(
      addon,
      StremioAddonCatalog(id: 'top', type: type, name: 'Popular'),
      skip: skip,
      onRawCount: (count) => raw = count,
    );
    return (
      items: [for (final item in items) item.withSourceAddon(addon)],
      rawCount: raw,
    );
  }
}
