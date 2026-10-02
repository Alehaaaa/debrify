import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/metadata_preferences.dart';
import '../models/stremio_addon.dart';
import 'metadata_explore_service.dart';

/// A studio credited on a title, by its IMDb company ID (`co…`).
class ImdbCompany {
  const ImdbCompany({
    required this.id,
    required this.name,
    required this.distributor,
    this.logoUrl,
  });

  final String id;
  final String name;

  /// Credited as a distributor/network rather than a production company.
  final bool distributor;

  /// Official logo from Wikidata (a rendered PNG), when one is recorded.
  final String? logoUrl;

  /// The numeric part of [id]; IMDb IDs zero-pad it to at least 7 digits.
  int get number => int.parse(id.substring(2));
}

/// One page of an IMDb credit search.
class ImdbTitlePage {
  const ImdbTitlePage(this.items, {this.cursor, this.hasMore = false});
  final List<StremioMeta> items;
  final String? cursor;
  final bool hasMore;
}

/// Studios and "more from this studio/person" without TMDB.
///
/// TMDB is the primary source for studios, networks and people pages, but its
/// token is baked in at build time. This is the token-free fallback, from the
/// same IMDb GraphQL endpoint the detail page already uses for its enrichment
/// (so the same headers apply), with studio logos from Wikidata/Wikipedia
/// (see [_logosFor]).
class ImdbCreditsService {
  ImdbCreditsService._();
  static final instance = ImdbCreditsService._();

  static const _imdbEndpoint = 'https://graphql.imdb.com/';
  static const _imdbHeaders = <String, String>{
    'Content-Type': 'application/json',
    'User-Agent': 'Mozilla/5.0',
    // IMDb's edge rejects this endpoint with 403 unless the request looks
    // like it came from imdb.com (see ImdbEnrichmentService).
    'Referer': 'https://www.imdb.com/',
  };
  static const _timeout = Duration(seconds: 12);

  final _companies = <String, List<ImdbCompany>>{};
  final _logos = <String, String?>{};

  static final _titleId = RegExp(r'^tt\d{7,9}$');
  static final _companyId = RegExp(r'^co\d{7,9}$');
  static final _nameId = RegExp(r'^nm\d{7,9}$');

  static bool isCompanyId(String? id) => id != null && _companyId.hasMatch(id);
  static bool isNameId(String? id) => id != null && _nameId.hasMatch(id);

  Future<Map<String, dynamic>?> _graphql(
    String query,
    Map<String, Object?> variables,
  ) async {
    final response = await http
        .post(
          Uri.parse(_imdbEndpoint),
          headers: _imdbHeaders,
          body: json.encode({'query': query, 'variables': variables}),
        )
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw http.ClientException('IMDb HTTP ${response.statusCode}');
    }
    final decoded = json.decode(response.body);
    if (decoded is! Map) throw const FormatException('Invalid IMDb response');
    final data = decoded['data'];
    return data is Map ? Map<String, dynamic>.from(data) : null;
  }

  static const _companiesQuery = r'''
    query ($id: ID!) {
      title(id: $id) {
        production: companyCredits(first: 6, filter: { categories: ["production"] }) {
          edges { node { company { id companyText { text } } } }
        }
        distribution: companyCredits(first: 2, filter: { categories: ["distribution"] }) {
          edges { node { company { id companyText { text } } } }
        }
      }
    }
  ''';

  /// Production companies, then distributors, each with a logo when
  /// Wikidata has one. Cached per title.
  Future<List<ImdbCompany>> companies(String titleId) async {
    if (!_titleId.hasMatch(titleId)) return const [];
    final cached = _companies[titleId];
    if (cached != null) return cached;
    final data = await _graphql(_companiesQuery, {'id': titleId});
    final title = data?['title'];
    if (title is! Map) return const [];
    final found = <String, ({String name, bool distributor})>{};
    for (final (key, distributor) in const [
      ('production', false),
      ('distribution', true),
    ]) {
      final edges = (title[key] as Map?)?['edges'];
      if (edges is! List) continue;
      for (final edge in edges) {
        final company = ((edge as Map?)?['node'] as Map?)?['company'];
        if (company is! Map) continue;
        final id = company['id'];
        final name = (company['companyText'] as Map?)?['text'];
        if (id is! String || !isCompanyId(id) || name is! String) continue;
        if (name.trim().isEmpty) continue;
        found.putIfAbsent(id, () => (name: name.trim(), distributor: distributor));
      }
    }
    final ids = found.keys.toList();
    final names = {for (final e in found.entries) e.key: e.value.name};
    final (logos, sizes) = await (
      _logosFor(ids, names),
      _creditCounts(ids),
    ).wait;
    final all = [
      for (final entry in found.entries)
        ImdbCompany(
          id: entry.key,
          name: entry.value.name,
          distributor: entry.value.distributor,
          logoUrl: logos[entry.key],
        ),
    ];
    // RELEVANCE: how many titles each studio is credited on. That puts the
    // names people know (Columbia, HBO: thousands) ahead of a production's
    // single-purpose shells (dozens). Ties keep IMDb's order.
    final order = {for (var i = 0; i < all.length; i++) all[i].id: i};
    all.sort((a, b) {
      final bySize = (sizes[b.id] ?? 0).compareTo(sizes[a.id] ?? 0);
      return bySize != 0 ? bySize : order[a.id]!.compareTo(order[b.id]!);
    });
    final result = List<ImdbCompany>.unmodifiable(all);
    _companies[titleId] = result;
    return result;
  }

  /// How many titles each company is credited on, in ONE IMDb request
  /// (aliased searches). Best effort: missing counts sort last.
  Future<Map<String, int>> _creditCounts(List<String> ids) async {
    final missing = ids.where((id) => !_counts.containsKey(id)).toList();
    if (missing.isNotEmpty) {
      try {
        final fields = [
          for (var i = 0; i < missing.length; i++)
            'c$i: advancedTitleSearch(first: 1, constraints: '
                '{ creditedCompanyConstraint: { anyCompanyIds: ["${missing[i]}"] } }) '
                '{ total }',
        ].join(' ');
        final data = await _graphql('query { $fields }', const {});
        for (var i = 0; i < missing.length; i++) {
          final total = (data?['c$i'] as Map?)?['total'];
          _counts[missing[i]] = total is int ? total : 0;
        }
      } catch (error) {
        debugPrint('ImdbCredits: studio sizes unavailable ($error)');
      }
    }
    return {for (final id in ids) id: _counts[id] ?? 0};
  }

  final _counts = <String, int>{};

  static const _wikiHeaders = <String, String>{
    // Wikimedia requires an identifying User-Agent.
    'User-Agent': 'Debrify/1.0 (https://github.com/Alehaaaa/debrify)',
  };

  Future<Map<String, dynamic>> _wikiGet(String host, Map<String, String> query) async {
    final response = await http
        .get(
          Uri.https(host, '/w/api.php', {...query, 'format': 'json'}),
          headers: _wikiHeaders,
        )
        .timeout(_timeout);
    if (response.statusCode != 200) {
      throw http.ClientException('Wikimedia HTTP ${response.statusCode}');
    }
    return Map<String, dynamic>.from(json.decode(response.body) as Map);
  }

  /// Compares names loosely: case, punctuation, "&"/"and" and a trailing
  /// "(HBO)"-style qualifier do not matter.
  static String _normalise(String name) => name
      .toLowerCase()
      .replaceAll(RegExp(r'\([^)]*\)'), '')
      .replaceAll('&', 'and')
      .replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// A Commons logo file rendered to a 320px PNG the image cache decodes.
  static String _commonsLogo(String file) => Uri.https(
    'commons.wikimedia.org',
    '/wiki/Special:FilePath/$file',
    {'width': '320'},
  ).toString();

  /// Logos for [ids], in three steps, each only for what is still missing:
  ///
  /// 1. Wikidata items carrying the EXACT IMDb company ID (P345) with a logo
  ///    (P154). Two requests for all companies together.
  /// 2. Wikidata items that have a logo and whose label or alias matches the
  ///    company name. Needed for the biggest studios: IMDb's ID for Columbia
  ///    Pictures belongs to a bare placeholder item, not the real one.
  /// 3. The English Wikipedia article's lead image — only when the file is
  ///    named as a logo (a company article often leads with a building).
  ///
  /// Uses the regular Wikimedia APIs, not the SPARQL query service, which
  /// rate-limits hard. Best effort throughout: a miss is a text tile.
  Future<Map<String, String?>> _logosFor(
    List<String> ids,
    Map<String, String> names,
  ) async {
    final missing = ids.where((id) => !_logos.containsKey(id)).toList();
    if (missing.isEmpty) return {for (final id in ids) id: _logos[id]};
    final found = <String, String>{};
    // A rate-limited or failed lookup must not be remembered as "no logo".
    var complete = true;
    try {
      // 1. Exact IMDb ID.
      final search = await _wikiGet('www.wikidata.org', {
        'action': 'query',
        'list': 'search',
        'srsearch':
            'haswbstatement:${missing.map((id) => 'P345=$id').join('|')}',
        'srlimit': '50',
        'srprop': '',
      });
      final items = [
        for (final hit in ((search['query'] as Map?)?['search'] as List?) ?? [])
          if ((hit as Map)['title'] is String) hit['title'] as String,
      ];
      if (items.isNotEmpty) {
        final entities = await _entities(items);
        for (final entity in entities.values) {
          final logo = _claim(entity, 'P154');
          if (logo == null) continue;
          for (final imdb in _claims(entity, 'P345')) {
            if (missing.contains(imdb)) found.putIfAbsent(imdb, () => logo);
          }
        }
      }
      // 2. Name match among items that have a logo.
      for (final id in missing.where((id) => !found.containsKey(id))) {
        final name = names[id];
        if (name == null) continue;
        final base = name.split(' (').first.trim();
        final hits = await _wikiGet('www.wikidata.org', {
          'action': 'query',
          'list': 'search',
          'srsearch': '"$base" haswbstatement:P154',
          'srlimit': '5',
          'srprop': '',
        });
        final candidates = [
          for (final hit in ((hits['query'] as Map?)?['search'] as List?) ?? [])
            if ((hit as Map)['title'] is String) hit['title'] as String,
        ];
        if (candidates.isEmpty) continue;
        final entities = await _entities(candidates, labels: true);
        final wanted = {_normalise(base), _normalise(name)};
        for (final candidate in candidates) {
          final entity = entities[candidate];
          if (entity == null) continue;
          final labels = [
            ((entity['labels'] as Map?)?['en'] as Map?)?['value'],
            for (final alias in ((entity['aliases'] as Map?)?['en'] as List?) ?? [])
              (alias as Map)['value'],
          ].whereType<String>();
          final logo = _claim(entity, 'P154');
          if (logo != null && labels.any((l) => wanted.contains(_normalise(l)))) {
            found[id] = logo;
            break;
          }
        }
      }
    } catch (error) {
      complete = false;
      debugPrint('ImdbCredits: Wikidata logos unavailable ($error)');
    }
    // 3. Wikipedia lead image, when it is plainly a logo. The page SUMMARY
    // (unlike the page-images API) includes non-free files, which is where
    // most studio logos live on English Wikipedia.
    for (final id in missing.where((id) => !found.containsKey(id))) {
      final name = names[id];
      if (name == null) continue;
      try {
        final title = name.split(' (').first.trim().replaceAll(' ', '_');
        final response = await http
            .get(
              Uri.https(
                'en.wikipedia.org',
                '/api/rest_v1/page/summary/${Uri.encodeComponent(title)}',
              ),
              headers: _wikiHeaders,
            )
            .timeout(_timeout);
        if (response.statusCode == 404) continue;
        if (response.statusCode != 200) {
          throw http.ClientException('Wikipedia HTTP ${response.statusCode}');
        }
        final summary = json.decode(response.body) as Map;
        final original = (summary['originalimage'] as Map?)?['source'];
        final thumb = (summary['thumbnail'] as Map?)?['source'];
        if (original is! String || thumb is! String) continue;
        final file = Uri.decodeComponent(Uri.parse(original).pathSegments.last);
        // Logos are named as such or drawn as SVG; an article that leads
        // with a photo (a headquarters, a founder) is a JPEG.
        // (Rendered thumbnails of an SVG are named `….svg.png`.)
        if (RegExp(r'logo|wordmark|\.svg(\.png)?$', caseSensitive: false)
            .hasMatch(file)) {
          found[id] = thumb;
        }
      } catch (error) {
        complete = false;
        debugPrint('ImdbCredits: Wikipedia logo unavailable ($error)');
      }
    }
    final result = <String, String?>{};
    for (final id in missing) {
      final logo = found[id];
      final url = logo == null
          ? null
          : logo.startsWith('https://')
          ? logo
          : _commonsLogo(logo);
      result[id] = url;
      if (url != null || complete) _logos[id] = url;
    }
    return {for (final id in ids) id: _logos[id] ?? result[id]};
  }

  Future<Map<String, Map>> _entities(
    List<String> items, {
    bool labels = false,
  }) async {
    final data = await _wikiGet('www.wikidata.org', {
      'action': 'wbgetentities',
      'ids': items.take(50).join('|'),
      'props': labels ? 'claims|labels|aliases' : 'claims',
      if (labels) 'languages': 'en',
    });
    final entities = data['entities'];
    if (entities is! Map) return const {};
    return {
      for (final entry in entities.entries)
        if (entry.key is String && entry.value is Map)
          entry.key as String: entry.value as Map,
    };
  }

  static Iterable<String> _claims(Map entity, String property) sync* {
    final claims = (entity['claims'] as Map?)?[property];
    if (claims is! List) return;
    for (final claim in claims) {
      final value = (((claim as Map)['mainsnak'] as Map?)?['datavalue']
          as Map?)?['value'];
      if (value is String) yield value;
    }
  }

  static String? _claim(Map entity, String property) {
    final values = _claims(entity, property);
    return values.isEmpty ? null : values.first;
  }

  static const _movieTypes = ['movie', 'tvMovie'];
  static const _seriesTypes = ['tvSeries', 'tvMiniSeries'];

  /// Titles credited to [companyId] or [nameId], most popular first.
  ///
  /// [type] is 'movie', 'tv', or null for both. [maxRuntimeMinutes] mirrors
  /// the browse page's "short" filter.
  Future<ImdbTitlePage> titles({
    String? companyId,
    String? nameId,
    String? type,
    String? after,
    int? maxRuntimeMinutes,
    String? language,
    int first = 30,
  }) async {
    final String constraint;
    final String ids;
    if (isCompanyId(companyId)) {
      constraint = 'creditedCompanyConstraint: { anyCompanyIds: \$ids }';
      ids = companyId!;
    } else if (isNameId(nameId)) {
      constraint = 'creditedNameConstraint: { anyNameIds: \$ids }';
      ids = nameId!;
    } else {
      return const ImdbTitlePage([]);
    }
    final types = switch (type) {
      'movie' => _movieTypes,
      'tv' => _seriesTypes,
      _ => [..._movieTypes, ..._seriesTypes],
    };
    final runtime = maxRuntimeMinutes == null
        ? ''
        : ', runtimeConstraint: { runtimeRangeMinutes: { max: $maxRuntimeMinutes } }';
    final lang = language != null && RegExp(r'^[a-z]{2,3}$').hasMatch(language)
        ? ', languageConstraint: { anyPrimaryLanguages: ["$language"] }'
        : '';
    final query = '''
      query (\$ids: [ID!]!, \$types: [String!]!, \$after: String, \$first: Int!) {
        advancedTitleSearch(first: \$first, after: \$after,
          constraints: { $constraint, titleTypeConstraint: { anyTitleTypeIds: \$types }$runtime$lang },
          sort: { sortBy: POPULARITY, sortOrder: ASC }) {
          pageInfo { hasNextPage endCursor }
          edges { node { title {
            id titleText { text } primaryImage { url } releaseYear { year }
            titleType { id } plot { plotText { plainText } }
          } } }
        }
      }
    ''';
    final data = await _graphql(query, {
      'ids': [ids],
      'types': types,
      'after': after,
      'first': first,
    });
    final search = data?['advancedTitleSearch'];
    if (search is! Map) return const ImdbTitlePage([]);
    final items = <StremioMeta>[];
    for (final edge in (search['edges'] as List?) ?? const []) {
      final title = ((edge as Map?)?['node'] as Map?)?['title'];
      if (title is! Map) continue;
      final id = title['id'];
      final name = (title['titleText'] as Map?)?['text'];
      if (id is! String || !_titleId.hasMatch(id) || name is! String) continue;
      final typeId = (title['titleType'] as Map?)?['id'];
      final year = (title['releaseYear'] as Map?)?['year'];
      items.add(
        StremioMeta(
          id: id,
          imdbId: id,
          type: _seriesTypes.contains(typeId) ? 'series' : 'movie',
          name: name,
          poster: (title['primaryImage'] as Map?)?['url'] as String?,
          description:
              ((title['plot'] as Map?)?['plotText'] as Map?)?['plainText']
                  as String?,
          year: year is int ? '$year' : null,
        ),
      );
    }
    final pageInfo = search['pageInfo'];
    final hasMore = pageInfo is Map && pageInfo['hasNextPage'] == true;
    return ImdbTitlePage(
      items,
      cursor: pageInfo is Map ? pageInfo['endCursor'] as String? : null,
      hasMore: hasMore,
    );
  }
}

/// Feeds [MetadataBrowsePage] from IMDb for one studio or person, so the
/// "more from this studio/actor" screen works without a TMDB token. The page
/// keeps its own UI; only where the titles come from changes.
class ImdbCreditBrowseService extends MetadataExploreService {
  ImdbCreditBrowseService.company(String this.companyId) : nameId = null;
  ImdbCreditBrowseService.person(String this.nameId) : companyId = null;

  final String? companyId;
  final String? nameId;

  /// IMDb pages by cursor; the page asks by number. Page N+1's cursor is the
  /// one page N returned.
  final _cursors = <String, String?>{};

  @override
  Future<MetadataBrowseResult> browse({
    required String kind,
    int? id,
    required MetadataPreferences preferences,
    int page = 1,
    String type = 'movie',
    Map<String, String> filters = const {},
  }) async {
    if (page < 1) return const MetadataBrowseResult([]);
    // Both follow the page's filters (Type, Runtime, Language), so a person
    // or studio browses exactly like any other Discover source.
    final scope = type;
    final short = int.tryParse(filters['with_runtime.lte'] ?? '');
    final language = filters['with_original_language'];
    final key = '$scope|$short|$language';
    final after = page == 1 ? null : _cursors['$key|$page'];
    if (page > 1 && after == null) return const MetadataBrowseResult([]);
    final result = await ImdbCreditsService.instance.titles(
      companyId: companyId,
      nameId: nameId,
      type: scope,
      after: after,
      maxRuntimeMinutes: short,
      language: language,
    );
    _cursors['$key|${page + 1}'] = result.cursor;
    return MetadataBrowseResult(result.items, hasMore: result.hasMore);
  }
}
