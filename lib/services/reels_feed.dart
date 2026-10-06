import 'dart:math' as math;

import '../models/stremio_addon.dart';
import 'metadata_preferences_service.dart';
import 'tmdb_metadata_repository.dart';

/// One TMDB request: `path` plus query, the JSON answer.
typedef ReelsTmdbGet =
    Future<Map<String, dynamic>> Function(
      String path,
      Map<String, String> query,
    );

/// A title ready for the feed: its details and the official clip to play.
class ReelTitle {
  const ReelTitle({
    required this.item,
    required this.clipKey,
    required this.clipName,
  });

  /// The title as the rest of the app knows it (IMDb id, Cinemeta-shaped).
  final StremioMeta item;

  /// YouTube id of the clip.
  final String clipKey;

  /// TMDB's name for the clip ("'The Hotel Lobby' Scene").
  final String clipName;
}

/// The titles Reels plays: official scene clips from TMDB, never trailers.
///
/// Built to be cheap. The source is TMDB's popular movie and TV lists — one
/// request brings 20 titles with their TMDB ids, so nothing has to be looked
/// up by IMDb id first — and each title then costs exactly ONE more request:
/// its details with the videos, logos and external ids appended. That single
/// answer says whether the title has a clip (no clip, no reel), and carries
/// the IMDb id, logo, localized overview and genre names the reel shows. The
/// requests for a batch run in parallel (the repository paces and caches
/// them), so a fling through the feed is never waiting on one title at a time.
///
/// Movies and shows alternate. A title is handed out once per app session,
/// and the clip is picked at random among its official clips, so a title
/// that comes back later shows another scene.
class ReelsFeed {
  ReelsFeed({
    ReelsTmdbGet? get,
    bool? configured,
    String? language,
    math.Random? random,
  }) : _get =
           get ??
           ((path, query) => TmdbMetadataRepository.instance.get(path, query)),
       available = configured ?? TmdbMetadataRepository.instance.configured,
       _language = language,
       _random = random ?? math.Random();

  final ReelsTmdbGet _get;
  final math.Random _random;
  String? _language;

  /// False when this build has no TMDB access (no clips to find).
  final bool available;

  /// Session-wide: a fresh feed (the tab remounts on every visit) never
  /// replays what this session already showed.
  static final Set<String> _shown = {};
  static final Map<String, ReelTitle> _known = {};
  static final Map<String, List<({String key, String name, bool official})>>
  _clipsByTitle = {};

  /// Test seam: forget what this session showed.
  static void resetSession() {
    _shown.clear();
    _known.clear();
    _clipsByTitle.clear();
  }

  static const _types = ['movie', 'tv'];
  final Map<String, List<Map<String, dynamic>>> _pool = {'movie': [], 'tv': []};
  final Map<String, int> _start = {};
  final Map<String, int> _page = {};
  final Map<String, int> _pages = {};
  final Set<String> _wrapped = {};
  final Set<String> _exhausted = {};
  int _turn = 0;
  final Set<String> _visited = {};
  final List<(String, ReelTitle)> _ready = [];
  bool _requestFailed = false;

  /// Distinguish unavailable metadata from a search that found no scene clips.
  bool get lastRequestFailed => _requestFailed;
  bool get exhausted => _exhausted.length == _types.length && _ready.isEmpty;

  /// Up to [count] titles that have a clip, in alternating movie/show order.
  /// Fewer (possibly none) when the lists run dry or TMDB is unreachable.
  Future<List<ReelTitle>> take(int count, {bool allowRepeat = false}) async {
    if (!available || count <= 0) return const [];
    final language = _language ??= await _loadLanguage();
    _requestFailed = false;
    final found = <ReelTitle>[];
    void drainReady() {
      while (_ready.isNotEmpty && found.length < count) {
        final (key, title) = _ready.removeAt(0);
        if (_shown.add(key)) {
          found.add(title);
          _known[key] = title;
        }
      }
    }

    drainReady();
    // Scene clips are sparse among popular titles. Even take(1) must search
    // a useful window instead of declaring the entire feed empty after six
    // candidates. Keep extra confirmed clips for the following swipe.
    for (var round = 0; round < 8 && found.length < count; round++) {
      final batch = <(String, Map<String, dynamic>)>[];
      while (batch.length < 8) {
        final next = await _nextCandidate(language);
        if (next == null) break;
        batch.add(next);
      }
      if (batch.isEmpty) break;
      final confirmed = await Future.wait([
        for (final (type, row) in batch) _confirm(type, row, language),
      ]);
      for (var i = 0; i < confirmed.length; i++) {
        final title = confirmed[i];
        if (title != null) {
          final key = '${batch[i].$1}:${batch[i].$2['id']}';
          _known[key] = title;
          _ready.add((key, title));
        }
      }
      drainReady();
      // A failed request is retryable; do not fan out more work on a broken
      // connection or consume the same failed candidates again in this call.
      if (_requestFailed) break;
    }
    // Continue with known playable scenes when the catalog is actually
    // exhausted. A scan budget or transport failure never starts a replay.
    if (allowRepeat &&
        found.length < count &&
        exhausted &&
        !_requestFailed &&
        _known.isNotEmpty) {
      final replay = _known.entries.toList()..shuffle(_random);
      for (final entry in replay) {
        _shown.remove(entry.key);
        final previous = entry.value;
        final options = (_clipsByTitle[entry.key] ?? const [])
            .where((clip) => clip.key != previous.clipKey)
            .toList();
        final alternate = options.isEmpty
            ? null
            : options[_random.nextInt(options.length)];
        _ready.add((
          entry.key,
          alternate == null
              ? previous
              : ReelTitle(
                  item: previous.item,
                  clipKey: alternate.key,
                  clipName: alternate.name,
                ),
        ));
      }
      drainReady();
    }
    return found;
  }

  /// The next unseen list row, alternating movie / show.
  Future<(String, Map<String, dynamic>)?> _nextCandidate(
    String language,
  ) async {
    for (var tries = 0; tries < _types.length * 2; tries++) {
      final type = _types[_turn++ % _types.length];
      if (_exhausted.contains(type)) continue;
      final pool = _pool[type]!;
      if (pool.isEmpty) {
        await _refill(type, language);
        if (_requestFailed) return null;
      }
      while (pool.isNotEmpty) {
        final row = pool.removeLast();
        final id = row['id'];
        if (id is! int ||
            _shown.contains('$type:$id') ||
            !_visited.add('$type:$id')) {
          continue;
        }
        return (type, row);
      }
    }
    return null;
  }

  Future<void> _refill(String type, String language) async {
    // Start a few pages in at random, so each session opens on something
    // different rather than the same top-of-chart titles; run to the end of
    // the list, then wrap round to the pages before the start. Each page is
    // asked for once.
    final start = _start[type] ??= _random.nextInt(3) + 1;
    var page = (_page[type] ?? start - 1) + 1;
    final last = _pages[type];
    if (last != null && page > last) {
      if (_wrapped.contains(type) || start == 1) {
        _exhausted.add(type);
        return;
      }
      _wrapped.add(type);
      page = 1;
    }
    if (_wrapped.contains(type) && page >= start) {
      _exhausted.add(type);
      return;
    }
    try {
      final data = await _get('$type/popular', {
        'language': language,
        'page': '$page',
      });
      final total = data['total_pages'];
      if (total is int) _pages[type] = math.min(total, 500);
      _page[type] = page;
      final rows = [
        for (final row in (data['results'] as List? ?? const []))
          if (row is Map<String, dynamic>) row,
      ]..shuffle(_random);
      // An empty page past the end of a short list: the next refill wraps.
      if (rows.isEmpty && (_wrapped.contains(type) || start == 1)) {
        _exhausted.add(type);
      }
      _pool[type]!.addAll(rows);
    } catch (_) {
      _requestFailed = true;
      // Leave the page cursor intact so Retry can request this page again.
    }
  }

  /// The title's one details request: clip, IMDb id, logo, overview, genres.
  Future<ReelTitle?> _confirm(
    String type,
    Map<String, dynamic> row,
    String language,
  ) async {
    try {
      final lang = language.split('-').first;
      final data = await _get('$type/${row['id']}', {
        'language': language,
        'append_to_response': 'videos,images,external_ids',
        'include_image_language': '$lang,en,null',
        'include_video_language': '$lang,en,null',
      });
      final clip = pickClip(data['videos'], _random);
      final imdb = (data['external_ids'] as Map?)?['imdb_id'];
      if (clip == null || imdb is! String || !imdb.startsWith('tt')) {
        return null;
      }
      final title =
          (data['title'] ?? data['name'] ?? row['title'] ?? row['name'])
              as String?;
      if (title == null || title.isEmpty) return null;
      _clipsByTitle['$type:${row['id']}'] = _clipPool(data['videos']);
      final date = (data['release_date'] ?? data['first_air_date']) as String?;
      return ReelTitle(
        item: StremioMeta(
          id: imdb,
          imdbId: imdb,
          type: type == 'tv' ? 'series' : 'movie',
          name: title,
          poster: TmdbMetadataRepository.image(
            data['poster_path'],
            size: 'w342',
          ),
          background: TmdbMetadataRepository.image(
            data['backdrop_path'],
            size: 'w1280',
          ),
          logo: _logo(data['images'], lang),
          description: (data['overview'] as String?)?.trim(),
          genres: [
            for (final genre in (data['genres'] as List? ?? const []))
              if (genre is Map && genre['name'] is String)
                genre['name'] as String,
          ],
          year: date != null && date.length >= 4 ? date.substring(0, 4) : null,
        ),
        clipKey: clip.key,
        clipName: clip.name,
      );
    } catch (_) {
      _requestFailed = true;
      _visited.remove('$type:${row['id']}');
      _pool[type]!.insert(0, row);
      return null;
    }
  }

  /// One of the title's official YouTube scene clips, at random — official
  /// uploads first; trailers, teasers and featurettes never.
  static ({String key, String name})? pickClip(
    Object? videos,
    math.Random random,
  ) {
    final pool = _clipPool(videos);
    if (pool.isEmpty) return null;
    final pick = pool[random.nextInt(pool.length)];
    return (key: pick.key, name: pick.name);
  }

  static List<({String key, String name, bool official})> _clipPool(
    Object? videos,
  ) {
    final rows = videos is Map ? videos['results'] : null;
    if (rows is! List) return const [];
    final clips = <({String key, String name, bool official})>[];
    final seen = <String>{};
    for (final row in rows) {
      if (row is! Map || row['site'] != 'YouTube' || row['type'] != 'Clip') {
        continue;
      }
      final key = row['key'];
      if (key is! String ||
          !RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(key) ||
          !seen.add(key)) {
        continue;
      }
      clips.add((
        key: key,
        name: (row['name'] as String?)?.trim() ?? '',
        official: row['official'] == true,
      ));
    }
    final official = clips.where((c) => c.official).toList();
    return official.isNotEmpty ? official : clips;
  }

  /// The title's logo in the reader's language, else English, else
  /// language-neutral art.
  static String? _logo(Object? images, String lang) {
    final logos = images is Map ? images['logos'] : null;
    if (logos is! List || logos.isEmpty) return null;
    Map? pick;
    for (final want in [lang, 'en', null]) {
      for (final logo in logos) {
        if (logo is Map && logo['iso_639_1'] == want) {
          pick = logo;
          break;
        }
      }
      if (pick != null) break;
    }
    pick ??= logos.first is Map ? logos.first as Map : null;
    return TmdbMetadataRepository.image(pick?['file_path'], size: 'w500');
  }

  static Future<String> _loadLanguage() async {
    try {
      return (await MetadataPreferencesService.load()).language;
    } catch (_) {
      return 'en-US';
    }
  }
}
