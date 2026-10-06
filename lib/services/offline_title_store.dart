import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../models/downloaded_media.dart';
import '../models/stremio_addon.dart';
import '../utils/app_storage.dart';
import '../utils/artwork_url.dart';
import 'app_migration_service.dart';
import 'debrify_image_cache.dart';
import 'imdb_enrichment_service.dart';
import 'imdb_parents_guide_service.dart';
import 'metadata_details_service.dart';
import 'stremio_service.dart';

/// Everything a downloaded title's detail page shows, kept on the device so
/// the page still works without a connection.
///
/// A title is "pinned" while any of its files is on the device or still
/// downloading (the library reports that through [updatePinned]). For pinned
/// titles this keeps:
///
/// * metadata slots — the catalog meta, the episode list, IMDb details,
///   parents guide and recommendations — written by the services and the
///   detail page whenever they load fresh data, and read back when the network
///   can't answer;
/// * artwork — every image the detail page loads through
///   [DebrifyImageCache.manager] while it is on screen, plus the title's own
///   art fetched ahead of time — stored outside the evictable image cache so
///   browsing other titles can never push it out.
///
/// Titles that stay gone from the library for a day are forgotten, files and
/// all.
class OfflineTitleStore {
  OfflineTitleStore._();
  static final instance = OfflineTitleStore._();

  /// Slot names.
  static const meta = 'meta';
  static const videos = 'videos';
  static const page = 'page';
  static const skipSegments = 'skip_segments';

  /// A removed download keeps its offline copy this long, so a drive that is
  /// briefly unplugged (or a library scan that couldn't read a folder) does
  /// not throw away everything that was saved.
  static const _forgetAfter = Duration(days: 1);

  /// How old a title's saved data may get before the library refreshes it.
  static const _refreshAfter = Duration(days: 3);

  @visibleForTesting
  static Future<Directory> Function()? debugDirectory;

  /// Tests that only exercise storage skip the ahead-of-time network save.
  @visibleForTesting
  static bool debugSkipWarm = false;

  @visibleForTesting
  static void debugReset() {
    instance
      .._dir = null
      .._loading = null
      .._pinned.clear()
      .._known.clear()
      .._images.clear()
      .._titles.clear()
      .._activePages.clear()
      .._warmed.clear();
  }

  /// Unit and widget tests never touch real storage or the network through
  /// this store unless they point it at a directory.
  static bool get _disabled =>
      kIsWeb ||
      (debugDirectory == null &&
          Platform.environment.containsKey('FLUTTER_TEST'));

  Directory? _dir;
  Future<void>? _loading;

  /// Titles with files on the device (or downloading) right now.
  final Set<String> _pinned = {};

  /// Every title with saved data: id → when it left the library (null while
  /// it is still there).
  final Map<String, int?> _known = {};

  /// Pinned artwork: url → (file name, owning title ids).
  final Map<String, ({String file, Set<String> owners})> _images = {};

  /// Loaded per-title slot maps.
  final Map<String, Map<String, dynamic>> _titles = {};

  /// Detail pages of pinned titles currently on top, innermost last.
  final List<String> _activePages = [];

  final Set<String> _warmed = {};
  Future<void> _writes = Future.value();

  bool isPinned(String? id) => id != null && _pinned.contains(id);

  /// Reads the index once; cheap to call repeatedly.
  Future<void> ensureLoaded() {
    if (_disabled) return Future.value();
    return _loading ??= _load();
  }

  Future<void> _load() async {
    try {
      final dir =
          await (debugDirectory?.call() ??
              AppStorage.support().then(
                (d) => Directory(p.join(d.path, 'offline_titles')),
              ));
      _dir = dir;
      final index = File(p.join(dir.path, 'index.json'));
      if (!await index.exists()) return;
      final decoded = jsonDecode(await index.readAsString());
      if (decoded is! Map) return;
      final titles = decoded['titles'];
      if (titles is Map) {
        for (final e in titles.entries) {
          if (e.key is! String) continue;
          final missing = e.value is Map ? e.value['missingSince'] : null;
          _known[e.key as String] = missing is int ? missing : null;
          if (missing is! int) _pinned.add(e.key as String);
        }
      }
      final images = decoded['images'];
      if (images is Map) {
        for (final e in images.entries) {
          final v = e.value;
          if (e.key is! String || v is! Map || v['file'] is! String) continue;
          _images[e.key as String] = (
            file: v['file'] as String,
            owners: {
              for (final o in (v['owners'] is List ? v['owners'] as List : []))
                if (o is String) o,
            },
          );
        }
      }
    } catch (_) {
      /* A damaged index only costs re-saving what pages show next. */
    }
  }

  // ── Library membership ────────────────────────────────────────────────────

  /// The library's current catalog titles (on the device or downloading).
  /// New ones get their details and artwork saved in the background; ones
  /// that have been gone for a day are forgotten.
  Future<void> updatePinned(Iterable<DownloadedMedia> titles) async {
    if (_disabled) return;
    final linked = {
      for (final media in titles)
        if (media.isCatalogLinked) media.id: media,
    };
    // Synchronous on purpose: pages listening to the same library load must
    // see the title as pinned by the time they hear about the download.
    _pinned
      ..clear()
      ..addAll(linked.keys);
    await ensureLoaded();
    _pinned
      ..clear()
      ..addAll(linked.keys);
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = false;
    for (final id in linked.keys) {
      if (!_known.containsKey(id) || _known[id] != null) {
        _known[id] = null;
        changed = true;
      }
    }
    for (final id in _known.keys.toList()) {
      if (linked.containsKey(id)) continue;
      final since = _known[id];
      if (since == null) {
        _known[id] = now;
        changed = true;
      } else if (now - since > _forgetAfter.inMilliseconds) {
        await _forget(id);
        changed = true;
      }
    }
    if (changed) await _saveIndex();
    for (final media in linked.values) {
      unawaited(_warm(media));
    }
  }

  Future<void> _forget(String id) async {
    _known.remove(id);
    _titles.remove(id);
    final dir = _dir;
    if (dir == null) return;
    try {
      final file = _titleFile(id);
      if (await file.exists()) await file.delete();
    } catch (_) {}
    for (final url in _images.keys.toList()) {
      final entry = _images[url]!;
      entry.owners.remove(id);
      if (entry.owners.isNotEmpty) continue;
      _images.remove(url);
      try {
        final file = File(p.join(dir.path, 'images', entry.file));
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  // ── Metadata slots ────────────────────────────────────────────────────────

  File _titleFile(String id) => File(
    p.join(_dir!.path, 'titles', '${sha1.convert(utf8.encode(id))}.json'),
  );

  Future<Map<String, dynamic>> _slots(String id) async {
    final loaded = _titles[id];
    if (loaded != null) return loaded;
    final slots = <String, dynamic>{};
    try {
      final file = _titleFile(id);
      if (await file.exists()) {
        final decoded = jsonDecode(await file.readAsString());
        if (decoded is Map && decoded['slots'] is Map) {
          slots.addAll(Map<String, dynamic>.from(decoded['slots'] as Map));
        }
      }
    } catch (_) {}
    return _titles[id] ??= slots;
  }

  /// Saved JSON for [slot] of title [id], or null.
  Future<Object?> read(String? id, String slot) async {
    if (id == null || _disabled) return null;
    await ensureLoaded();
    if (_dir == null || !_known.containsKey(id)) return null;
    final value = (await _slots(id))[slot];
    return value is Map ? value['data'] : null;
  }

  /// Saves [data] (plain JSON) as [slot] of title [id]. Ignored for titles
  /// that aren't downloaded.
  Future<void> write(String? id, String slot, Object? data) async {
    if (id == null || data == null || !isPinned(id) || _disabled) return;
    await ensureLoaded();
    if (_dir == null) return;
    final slots = await _slots(id);
    final previous = slots[slot];
    final encoded = jsonEncode(data);
    if (previous is Map && jsonEncode(previous['data']) == encoded) return;
    slots[slot] = {
      'savedAt': DateTime.now().millisecondsSinceEpoch,
      'data': jsonDecode(encoded),
    };
    final isNew = !_known.containsKey(id);
    _known[id] = null;
    await _enqueue(() async {
      final file = _titleFile(id);
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'id': id, 'slots': slots}));
    });
    if (isNew) await _saveIndex();
  }

  Future<int?> _savedAt(String id, String slot) async {
    if (!_known.containsKey(id)) return null;
    final value = (await _slots(id))[slot];
    return value is Map && value['savedAt'] is int
        ? value['savedAt'] as int
        : null;
  }

  // ── Artwork ───────────────────────────────────────────────────────────────

  /// The saved copy of [url], when one exists.
  Future<File?> imageFile(String url) async {
    if (_disabled) return null;
    await ensureLoaded();
    final entry = _images[url];
    final dir = _dir;
    if (entry == null || dir == null) return null;
    final file = File(p.join(dir.path, 'images', entry.file));
    return await file.exists() ? file : null;
  }

  /// Whether [url] has a saved copy (only meaningful once loaded).
  bool hasImage(String? url) => url != null && _images.containsKey(url);

  /// The pinned title whose detail page is on screen, if any. Artwork loaded
  /// while it is set is saved for that title.
  String? get activeImageOwner =>
      _activePages.isEmpty ? null : _activePages.last;

  void enterPage(String id) {
    _activePages
      ..remove(id)
      ..add(id);
  }

  void leavePage(String id) => _activePages.remove(id);

  /// Saves [url] for title [id]. [source] is an already downloaded copy;
  /// without one the image is fetched through the shared image cache.
  Future<void> pinImage(String? id, String? url, {String? source}) async {
    if (id == null || url == null || url.isEmpty || _disabled) return;
    if (!url.startsWith('http://') && !url.startsWith('https://')) return;
    await ensureLoaded();
    final dir = _dir;
    if (dir == null || !isPinned(id)) return;
    final existing = _images[url];
    if (existing != null &&
        await File(p.join(dir.path, 'images', existing.file)).exists()) {
      if (existing.owners.add(id)) await _saveIndex();
      return;
    }
    try {
      final cached = source == null
          ? await DebrifyImageCache.manager.getFileFromCache(url)
          : null;
      final from =
          source ??
          (cached != null && await cached.file.exists()
              ? cached.file.path
              : (await DebrifyImageCache.manager.getSingleFile(url)).path);
      final name = '${sha1.convert(utf8.encode(url))}${_extension(url, from)}';
      final target = File(p.join(dir.path, 'images', name));
      await target.parent.create(recursive: true);
      await File(from).copy(target.path);
      _images[url] = (file: name, owners: {id});
      await _saveIndex();
    } catch (_) {
      /* Missing artwork falls back to the page's placeholders. */
    }
  }

  static String _extension(String url, String path) {
    final fromPath = p.extension(path).toLowerCase();
    if (const {'.jpg', '.jpeg', '.png', '.webp', '.gif'}.contains(fromPath)) {
      return fromPath;
    }
    final fromUrl = p.extension(Uri.tryParse(url)?.path ?? '').toLowerCase();
    return fromUrl.length > 1 && fromUrl.length <= 5 ? fromUrl : '.img';
  }

  // ── Persistence ───────────────────────────────────────────────────────────

  Future<void> _enqueue(Future<void> Function() action) {
    final next = _writes.then((_) => action()).catchError((_) {});
    _writes = next;
    return next;
  }

  Future<void> _saveIndex() => _enqueue(() async {
    final dir = _dir;
    if (dir == null) return;
    await dir.create(recursive: true);
    await File(p.join(dir.path, 'index.json')).writeAsString(
      jsonEncode({
        'version': 1,
        'titles': {
          for (final e in _known.entries)
            e.key: {if (e.value != null) 'missingSince': e.value},
        },
        'images': {
          for (final e in _images.entries)
            e.key: {'file': e.value.file, 'owners': e.value.owners.toList()},
        },
      }),
    );
  });

  // ── Ahead-of-time save ────────────────────────────────────────────────────

  /// Saves a downloaded title's details and artwork without its page being
  /// opened: the catalog meta and episode list (stored by [StremioService]
  /// itself), IMDb details, parents guide, recommendations, and the art all
  /// of those point at. Runs once per title per session, and only when the
  /// saved copy is missing or old. Offline, every fetch simply fails and the
  /// existing copy stays.
  Future<void> _warm(DownloadedMedia media) async {
    if (debugSkipWarm || !_warmed.add(media.id)) return;
    // Save shelf artwork before any catalog/enrichment request. A new download
    // can be browsed offline even if the full background warm never finishes.
    unawaited(pinImage(media.id, media.poster));
    unawaited(pinImage(media.id, highQualityArtworkUrl(media.poster)));
    final savedAt = await _savedAt(media.id, page);
    if (savedAt != null &&
        DateTime.now().millisecondsSinceEpoch - savedAt <
            _refreshAfter.inMilliseconds) {
      return;
    }
    try {
      final stremio = StremioService.instance;
      final full = await stremio.fetchMetaDetails(
        imdbId: media.id,
        type: media.type,
      );
      if (!isPinned(media.id)) return;
      final item =
          full ??
          StremioMeta(
            id: media.id,
            imdbId: media.id.startsWith('tt') ? media.id : null,
            type: media.type,
            name: media.title,
            poster: media.poster,
            year: media.year,
          );
      var episodes = const <Map<String, dynamic>>[];
      if (media.type == 'series') {
        episodes =
            await stremio.fetchSeriesMeta(await cinemetaAddon(), media.id) ??
            const [];
      }
      final imdbId = item.effectiveImdbId;
      final results = await Future.wait<Object?>([
        MetadataDetailsService.instance
            .enrich(
              item,
              loadExisting: () async =>
                  imdbId == null ? null : ImdbEnrichmentService.fetch(imdbId),
            )
            .catchError((Object _) => null),
        imdbId == null
            ? Future<Object?>.value()
            : ImdbParentsGuideService.fetch(
                imdbId,
              ).catchError((Object _) => null),
        MetadataDetailsService.instance
            .recommendations(item, null)
            .catchError((Object _) => const <StremioMeta>[]),
      ]);
      final details = results[0] as ImdbEnrichment?;
      final guide = results[1] as ParentsGuideResult?;
      final recs = results[2] as List<StremioMeta>;
      if (!isPinned(media.id)) return;
      final previous = PageSnapshot.fromJson(await read(media.id, page));
      final snapshot = PageSnapshot(
        meta: full ?? previous?.meta,
        details: details ?? previous?.details,
        parentsGuide: guide ?? previous?.parentsGuide,
        recommendations: recs.isNotEmpty
            ? recs
            : (previous?.recommendations ?? const []),
      );
      if (full != null || details != null || guide != null || recs.isNotEmpty) {
        await write(media.id, page, snapshot.toJson());
      }
      for (final url in {
        media.poster,
        highQualityArtworkUrl(media.poster),
        ...snapshot.imageUrls,
        for (final video in episodes) ...episodeImageUrls(video['thumbnail']),
      }) {
        if (!isPinned(media.id)) return;
        await pinImage(media.id, url);
      }
    } catch (_) {
      // Another attempt happens next session.
      _warmed.remove(media.id);
    }
  }

  /// The URLs an episode still is requested under: the addon's own and the
  /// smaller Cinemeta size the episode list asks for.
  static List<String> episodeImageUrls(Object? thumbnail) {
    if (thumbnail is! String || thumbnail.isEmpty) return const [];
    return [
      thumbnail,
      if (thumbnail.contains('episodes.metahub.space'))
        thumbnail.replaceFirst(RegExp(r'/w\d+\.jpg$'), '/w300.jpg'),
    ];
  }

  /// The user's Cinemeta install when present, else the stock one — used for
  /// metadata only.
  static Future<StremioAddon> cinemetaAddon() async {
    try {
      final addons = await StremioService.instance.getEnabledAddons();
      for (final addon in addons) {
        if (StremioService.isCinemetaAddon(addon)) return addon;
      }
    } catch (_) {}
    return StremioAddon(
      id: 'com.linvo.cinemeta',
      name: 'Cinemeta',
      manifestUrl: AppMigrationService.cinemetaManifestUrl,
      baseUrl: 'https://v3-cinemeta.strem.io',
      types: const ['movie', 'series'],
      resources: const ['catalog', 'meta'],
      idPrefixes: const ['tt'],
    );
  }
}

/// What a detail page last showed for a downloaded title.
class PageSnapshot {
  const PageSnapshot({
    this.meta,
    this.details,
    this.parentsGuide,
    this.recommendations = const [],
  });

  final StremioMeta? meta;
  final ImdbEnrichment? details;
  final ParentsGuideResult? parentsGuide;
  final List<StremioMeta> recommendations;

  Map<String, dynamic> toJson() => {
    if (meta != null) 'meta': meta!.toJson(),
    if (details != null) 'details': imdbEnrichmentToJson(details!),
    if (parentsGuide != null) 'parentsGuide': parentsGuideToJson(parentsGuide!),
    if (recommendations.isNotEmpty)
      'recommendations': [for (final r in recommendations) r.toJson()],
  };

  static PageSnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    try {
      final meta = raw['meta'];
      final recs = raw['recommendations'];
      return PageSnapshot(
        meta: meta is Map
            ? StremioMeta.fromJson(Map<String, dynamic>.from(meta))
            : null,
        details: imdbEnrichmentFromJson(raw['details']),
        parentsGuide: parentsGuideFromJson(raw['parentsGuide']),
        recommendations: [
          if (recs is List)
            for (final r in recs)
              if (r is Map) StremioMeta.fromJson(Map<String, dynamic>.from(r)),
        ],
      );
    } catch (_) {
      return null;
    }
  }

  /// Artwork the snapshot points at — the poster and backdrop also in the
  /// full-size version the detail page's hero asks for.
  Iterable<String> get imageUrls sync* {
    for (final url in [
      meta?.poster,
      highQualityArtworkUrl(meta?.poster),
      meta?.background,
      highQualityArtworkUrl(meta?.background),
      meta?.logo,
      for (final c in details?.cast ?? const <CastMember>[]) c.imageUrl,
      for (final u in details?.universe ?? const <UniverseTitle>[]) u.posterUrl,
      for (final r in recommendations) r.poster,
    ]) {
      if (url != null && url.isNotEmpty) yield url;
    }
  }
}

// ── Serialisation for the IMDb models (kept here so the models stay plain) ──

Map<String, dynamic> imdbEnrichmentToJson(ImdbEnrichment e) => {
  'plot': e.plot,
  'runtime': e.runtime,
  'certificate': e.certificate,
  'rating': e.rating,
  'voteCount': e.voteCount,
  'director': e.director,
  'stars': e.stars,
  'cast': [
    for (final c in e.cast)
      {
        'name': c.name,
        'character': c.character,
        'imageUrl': c.imageUrl,
        'tmdbPersonId': c.tmdbPersonId,
        'imdbPersonId': c.imdbPersonId,
      },
  ],
  'genres': e.genres,
  'awardWins': e.awardWins,
  'awardNominations': e.awardNominations,
  'tagline': e.tagline,
  'year': e.year,
  'countries': e.countries,
  'languages': e.languages,
  'productionCompany': e.productionCompany,
  'boxOffice': e.boxOffice,
  'metacriticScore': e.metacriticScore,
  'runtimeMinutes': e.runtimeMinutes,
  'top250Rank': e.top250Rank,
  'meterRank': e.meterRank,
  'meterDelta': e.meterDelta,
  'didYouKnow': [
    for (final d in e.didYouKnow) {'kind': d.kind, 'text': d.text},
  ],
  'triviaTotal': e.triviaTotal,
  'goofsTotal': e.goofsTotal,
  'quotesTotal': e.quotesTotal,
  'universe': [
    for (final u in e.universe)
      {
        'imdbId': u.imdbId,
        'name': u.name,
        'relation': u.relation,
        'posterUrl': u.posterUrl,
        'year': u.year,
        'endYear': u.endYear,
        'isSeries': u.isSeries,
      },
  ],
};

ImdbEnrichment? imdbEnrichmentFromJson(Object? raw) {
  if (raw is! Map) return null;
  String? s(Object? v) => v is String ? v : null;
  int? i(Object? v) => v is num ? v.toInt() : null;
  List<String> strings(Object? v) =>
      v is List ? v.whereType<String>().toList() : const [];
  List<Map> maps(Object? v) =>
      v is List ? v.whereType<Map>().toList() : const [];
  return ImdbEnrichment(
    plot: s(raw['plot']),
    runtime: s(raw['runtime']),
    certificate: s(raw['certificate']),
    rating: (raw['rating'] as num?)?.toDouble(),
    voteCount: i(raw['voteCount']),
    director: s(raw['director']),
    stars: strings(raw['stars']),
    cast: [
      for (final c in maps(raw['cast']))
        if (c['name'] is String)
          CastMember(
            name: c['name'] as String,
            character: s(c['character']),
            imageUrl: s(c['imageUrl']),
            tmdbPersonId: i(c['tmdbPersonId']),
            imdbPersonId: s(c['imdbPersonId']),
          ),
    ],
    genres: strings(raw['genres']),
    awardWins: i(raw['awardWins']),
    awardNominations: i(raw['awardNominations']),
    tagline: s(raw['tagline']),
    year: s(raw['year']),
    countries: strings(raw['countries']),
    languages: strings(raw['languages']),
    productionCompany: s(raw['productionCompany']),
    boxOffice: s(raw['boxOffice']),
    metacriticScore: i(raw['metacriticScore']),
    runtimeMinutes: i(raw['runtimeMinutes']),
    top250Rank: i(raw['top250Rank']),
    meterRank: i(raw['meterRank']),
    meterDelta: i(raw['meterDelta']),
    didYouKnow: [
      for (final d in maps(raw['didYouKnow']))
        if (d['kind'] is String && d['text'] is String)
          DidYouKnowEntry(kind: d['kind'] as String, text: d['text'] as String),
    ],
    triviaTotal: i(raw['triviaTotal']) ?? 0,
    goofsTotal: i(raw['goofsTotal']) ?? 0,
    quotesTotal: i(raw['quotesTotal']) ?? 0,
    universe: [
      for (final u in maps(raw['universe']))
        if (u['imdbId'] is String &&
            u['name'] is String &&
            u['relation'] is String)
          UniverseTitle(
            imdbId: u['imdbId'] as String,
            name: u['name'] as String,
            relation: u['relation'] as String,
            posterUrl: s(u['posterUrl']),
            year: i(u['year']),
            endYear: i(u['endYear']),
            isSeries: u['isSeries'] == true,
          ),
    ],
  );
}

Map<String, dynamic> parentsGuideToJson(ParentsGuideResult g) => {
  'categories': [
    for (final c in g.categories)
      {
        'id': c.id,
        'label': c.label,
        'severity': c.severity,
        'severityVotes': c.severityVotes,
        'totalVotes': c.totalVotes,
        'items': [
          for (final item in c.items)
            {'text': item.text, 'isSpoiler': item.isSpoiler},
        ],
      },
  ],
};

ParentsGuideResult? parentsGuideFromJson(Object? raw) {
  if (raw is! Map || raw['categories'] is! List) return null;
  return ParentsGuideResult(
    categories: [
      for (final c in (raw['categories'] as List).whereType<Map>())
        ParentsGuideCategory(
          id: '${c['id'] ?? ''}',
          label: '${c['label'] ?? ''}',
          severity: '${c['severity'] ?? ''}',
          severityVotes: (c['severityVotes'] as num?)?.toInt() ?? 0,
          totalVotes: (c['totalVotes'] as num?)?.toInt() ?? 0,
          items: [
            for (final item
                in (c['items'] is List ? c['items'] as List : const [])
                    .whereType<Map>())
              if (item['text'] is String)
                ParentsGuideItem(
                  text: item['text'] as String,
                  isSpoiler: item['isSpoiler'] == true,
                ),
          ],
        ),
    ],
  );
}
