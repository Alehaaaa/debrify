import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Rotten Tomatoes scores for poster tiles, looked up on OMDb by IMDb id.
///
/// OMDb's free key allows ~1,000 requests a day, so this is built to spend as
/// few as possible:
/// - only ids a mounted tile actually asks for are fetched (never whole rows);
/// - every answer — including "no RT score" — is persisted on device, and
///   how long it stays trusted depends on how settled it is (see [ttlFor]):
///   a film out for over a year has a Tomatometer that no longer moves, so
///   it is effectively fetched once; only new releases and running series
///   are rechecked;
/// - concurrent asks for the same id share one request;
/// - "Request limit reached!" pauses all traffic for [_limitCooldown].
///
/// The key comes from `--dart-define=OMDB_API_KEY=…` (or `.env.local.json`).
/// Without one, [enabled] is false and nothing is ever requested.
class OmdbRatingsService {
  OmdbRatingsService({
    String apiKey = const String.fromEnvironment('OMDB_API_KEY'),
    http.Client Function()? clientFactory,
    DateTime Function()? now,
    Future<SharedPreferences> Function()? prefs,
  }) : _apiKey = apiKey.trim(),
       _clientFactory = clientFactory ?? http.Client.new,
       _now = now ?? DateTime.now,
       _prefs = prefs ?? SharedPreferences.getInstance;

  static final instance = OmdbRatingsService();

  // v2 adds Metacritic + IMDb; v1 entries would be trusted without them.
  static const _prefsKey = 'omdb_ratings_cache_v2';
  static const _seasonPrefsKey = 'omdb_season_cache_v1';
  static const _maxSeasons = 1500;
  static const _limitCooldown = Duration(hours: 3);
  static const _failureCooldown = Duration(minutes: 2);
  static const _maxEntries = 5000;
  static const _maxConcurrent = 3;
  static final _imdbId = RegExp(r'^tt\d{5,10}$');

  final String _apiKey;
  final http.Client Function() _clientFactory;
  final DateTime Function() _now;
  final Future<SharedPreferences> Function() _prefs;

  bool get enabled => _apiKey.isNotEmpty;

  /// imdbId → score 0..100 (null when OMDb has none), when it was fetched,
  /// when the title was released and whether it is a still-running series.
  final _cache = <String, OmdbCacheEntry>{};

  /// "tt…:season" → IMDb episode ratings for that season.
  final _seasons = <String, OmdbSeasonEntry>{};
  final _seasonPending = <String, Future<Map<int, double>?>>{};
  final _listeners = <String, Set<VoidCallback>>{};
  final _queue = Queue<String>();
  final _queued = <String>{};
  final _inFlight = <String>{};
  final _failedUntil = <String, DateTime>{};
  DateTime? _pausedUntil;
  Future<void>? _loading;
  bool _loaded = false;
  Timer? _saveTimer;
  Timer? _resumeTimer;

  static bool isImdbId(String? id) => id != null && _imdbId.hasMatch(id);

  /// The cached Tomatometer for [imdbId], or null when unknown / not on RT.
  int? scoreFor(String? imdbId) =>
      imdbId == null ? null : _cache[imdbId]?.score;

  /// Every rating OMDb had for [imdbId] (null until fetched).
  OmdbCacheEntry? ratingsFor(String? imdbId) =>
      imdbId == null ? null : _cache[imdbId];

  /// Calls [listener] whenever [imdbId]'s score arrives. Also triggers a fetch
  /// when the cached value is missing or stale.
  void addListener(String imdbId, VoidCallback listener) {
    (_listeners[imdbId] ??= <VoidCallback>{}).add(listener);
    request(imdbId);
  }

  void removeListener(String imdbId, VoidCallback listener) {
    final set = _listeners[imdbId];
    if (set == null) return;
    set.remove(listener);
    if (set.isEmpty) {
      _listeners.remove(imdbId);
      // Nobody is looking at it any more — don't spend quota on it.
      if (_queued.remove(imdbId)) _queue.remove(imdbId);
    }
  }

  void request(String imdbId) {
    if (!enabled || !isImdbId(imdbId)) return;
    if (!_loaded) {
      unawaited(_ensureLoaded().then((_) => request(imdbId)));
      return;
    }
    if (_isFresh(imdbId)) return;
    if (_inFlight.contains(imdbId) || _queued.contains(imdbId)) return;
    final failed = _failedUntil[imdbId];
    if (failed != null && failed.isAfter(_now())) return;
    _queued.add(imdbId);
    _queue.add(imdbId);
    _pump();
  }

  bool _isFresh(String imdbId) {
    final entry = _cache[imdbId];
    if (entry == null) return false;
    return _now().difference(entry.at) < ttlFor(entry, _now());
  }

  /// How long a cached answer is trusted. Tomatometers swing in a title's
  /// first weeks (reviews still landing) and then freeze; titles with no RT
  /// page years after release almost never get one.
  @visibleForTesting
  static Duration ttlFor(OmdbCacheEntry entry, DateTime now) {
    final released = entry.released;
    final age = released == null ? null : now.difference(released);
    final missing = entry.isEmpty;
    if (entry.ongoing) {
      // Running series: new seasons move the aggregate.
      return const Duration(days: 30);
    }
    if (age == null) {
      return missing ? const Duration(days: 14) : const Duration(days: 60);
    }
    if (age.isNegative || age < const Duration(days: 90)) {
      // Unreleased / brand new: reviews are still coming in.
      return missing ? const Duration(days: 2) : const Duration(days: 4);
    }
    if (age < const Duration(days: 365)) {
      return missing ? const Duration(days: 14) : const Duration(days: 30);
    }
    // Settled. A year, so a rare re-review or late RT page still turns up.
    return missing ? const Duration(days: 180) : const Duration(days: 365);
  }

  /// "14 Oct 1994" → date; falls back to Jan 1 of the first year in "Year".
  @visibleForTesting
  static DateTime? parseReleased(Map<dynamic, dynamic> body) {
    const months = {
      'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
      'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
    };
    final m = RegExp(r'^(\d{1,2}) ([A-Za-z]{3}) (\d{4})$')
        .firstMatch('${body['Released'] ?? ''}'.trim());
    if (m != null) {
      final month = months[m.group(2)!.toLowerCase()];
      if (month != null) {
        return DateTime(int.parse(m.group(3)!), month, int.parse(m.group(1)!));
      }
    }
    final y = RegExp(r'(\d{4})').firstMatch('${body['Year'] ?? ''}');
    return y == null ? null : DateTime(int.parse(y.group(1)!));
  }

  /// A series whose "Year" is open-ended ("2019–").
  @visibleForTesting
  static bool parseOngoing(Map<dynamic, dynamic> body) =>
      '${body['Type']}'.toLowerCase() == 'series' &&
      RegExp(r'^\d{4}\s*[–-]\s*$').hasMatch('${body['Year'] ?? ''}'.trim());

  void _pump() {
    final paused = _pausedUntil;
    if (paused != null && paused.isAfter(_now())) return;
    while (_inFlight.length < _maxConcurrent && _queue.isNotEmpty) {
      final id = _queue.removeFirst();
      _queued.remove(id);
      _inFlight.add(id);
      unawaited(_fetch(id).whenComplete(() {
        _inFlight.remove(id);
        _pump();
      }));
    }
  }

  Future<void> _fetch(String imdbId) async {
    final client = _clientFactory();
    try {
      final uri = Uri.https('www.omdbapi.com', '/', {
        'apikey': _apiKey,
        'i': imdbId,
        'tomatoes': 'true',
      });
      final response = await client.get(uri).timeout(
        const Duration(seconds: 10),
      );
      final body = jsonDecode(response.body);
      if (body is! Map) throw const FormatException('Unexpected OMDb body');
      final ok = '${body['Response']}'.toLowerCase() == 'true';
      if (!ok) {
        final error = '${body['Error'] ?? ''}'.toLowerCase();
        if (error.contains('limit') || error.contains('invalid api key')) {
          // Daily quota spent (or bad key): stop asking for a while.
          _pausedUntil = _now().add(_limitCooldown);
          _resumeTimer?.cancel();
          _resumeTimer = Timer(_limitCooldown, _pump);
          if (_listeners.containsKey(imdbId) && _queued.add(imdbId)) {
            _queue.addFirst(imdbId);
          }
          return;
        }
        // "Incorrect IMDb ID", "Movie not found!" — a real, cacheable miss.
        _store(imdbId, OmdbCacheEntry(score: null, at: _now()));
        return;
      }
      _store(
        imdbId,
        OmdbCacheEntry(
          score: parseRottenTomatoes(body),
          metacritic: parseMetacritic(body),
          imdb: parseImdb(body),
          at: _now(),
          released: parseReleased(body),
          ongoing: parseOngoing(body),
        ),
      );
    } catch (_) {
      // Offline / timeout / bad payload — try again later, don't cache.
      _failedUntil[imdbId] = _now().add(_failureCooldown);
    } finally {
      client.close();
    }
  }

  /// IMDb ratings (episode number → 0..10) for one season of [showImdbId].
  /// Served from the device cache while it is trusted (see [seasonTtlFor]);
  /// a season that finished airing over a year ago is effectively fetched
  /// once. Returns the stale copy, if any, when OMDb can't be reached.
  Future<Map<int, double>?> seasonRatings(String showImdbId, int season) async {
    if (!enabled || !isImdbId(showImdbId) || season < 1) return null;
    await _ensureLoaded();
    final key = '$showImdbId:$season';
    final cached = _seasons[key];
    if (cached != null &&
        _now().difference(cached.at) < seasonTtlFor(cached, _now())) {
      return cached.ratings;
    }
    final paused = _pausedUntil;
    if (paused != null && paused.isAfter(_now())) return cached?.ratings;
    return _seasonPending[key] ??= _fetchSeason(showImdbId, season, cached)
        .whenComplete(() {
      // A block body: `=> remove(key)` would return this very future and
      // make whenComplete wait on itself.
      _seasonPending.remove(key);
    });
  }

  Future<Map<int, double>?> _fetchSeason(
    String showImdbId,
    int season,
    OmdbSeasonEntry? stale,
  ) async {
    final client = _clientFactory();
    try {
      final uri = Uri.https('www.omdbapi.com', '/', {
        'apikey': _apiKey,
        'i': showImdbId,
        'Season': '$season',
      });
      final response = await client.get(uri).timeout(
        const Duration(seconds: 10),
      );
      final body = jsonDecode(response.body);
      if (body is! Map) return stale?.ratings;
      if ('${body['Response']}'.toLowerCase() != 'true') {
        final error = '${body['Error'] ?? ''}'.toLowerCase();
        if (error.contains('limit') || error.contains('invalid api key')) {
          _pausedUntil = _now().add(_limitCooldown);
          return stale?.ratings;
        }
        _storeSeason(showImdbId, season, OmdbSeasonEntry(ratings: const {}, at: _now()));
        return const {};
      }
      final entry = parseSeason(body, _now());
      _storeSeason(showImdbId, season, entry);
      return entry.ratings;
    } catch (_) {
      return stale?.ratings;
    } finally {
      client.close();
    }
  }

  void _storeSeason(String id, int season, OmdbSeasonEntry entry) {
    final key = '$id:$season';
    _seasons.remove(key);
    _seasons[key] = entry;
    while (_seasons.length > _maxSeasons) {
      _seasons.remove(_seasons.keys.first);
    }
    _scheduleSave();
  }

  /// An OMDb `&Season=` payload → ratings + when its last episode aired.
  @visibleForTesting
  static OmdbSeasonEntry parseSeason(Map<dynamic, dynamic> body, DateTime now) {
    final ratings = <int, double>{};
    DateTime? lastAired;
    var future = false, undated = false;
    final episodes = body['Episodes'];
    if (episodes is List) {
      for (final raw in episodes) {
        if (raw is! Map) continue;
        final number = int.tryParse('${raw['Episode']}');
        if (number == null) continue;
        final rating = double.tryParse('${raw['imdbRating']}');
        if (rating != null && rating > 0 && rating <= 10) {
          ratings[number] = rating;
        }
        final aired = DateTime.tryParse('${raw['Released']}');
        if (aired == null) {
          undated = true;
        } else if (aired.isAfter(now)) {
          future = true;
        } else if (lastAired == null || aired.isAfter(lastAired)) {
          lastAired = aired;
        }
      }
    }
    return OmdbSeasonEntry(
      ratings: ratings,
      at: now,
      lastAired: lastAired,
      // An undated stray (unaired pilot, special) on a long-finished season
      // doesn't make it "airing".
      airing: future ||
          (undated &&
              (lastAired == null ||
                  now.difference(lastAired) < const Duration(days: 365))),
    );
  }

  /// Episode ratings move while a season airs and for a few weeks after,
  /// then settle; a long-finished season is trusted for a year.
  @visibleForTesting
  static Duration seasonTtlFor(OmdbSeasonEntry entry, DateTime now) {
    if (entry.airing) return const Duration(days: 2);
    final last = entry.lastAired;
    if (last == null) return const Duration(days: 14);
    final age = now.difference(last);
    if (age < const Duration(days: 60)) return const Duration(days: 3);
    if (age < const Duration(days: 365)) return const Duration(days: 30);
    return const Duration(days: 365);
  }

  /// The Metascore (0..100) from an OMDb title payload, or null.
  @visibleForTesting
  static int? parseMetacritic(Map<dynamic, dynamic> body) {
    final ratings = body['Ratings'];
    if (ratings is List) {
      for (final raw in ratings) {
        if (raw is! Map || '${raw['Source']}'.toLowerCase() != 'metacritic') {
          continue;
        }
        final m = RegExp(r'^(\d{1,3})').firstMatch('${raw['Value']}'.trim());
        final v = m == null ? null : int.tryParse(m.group(1)!);
        if (v != null && v <= 100) return v;
      }
    }
    final v = int.tryParse('${body['Metascore'] ?? ''}');
    return v != null && v >= 0 && v <= 100 ? v : null;
  }

  /// The IMDb rating (0..10) from an OMDb title payload, or null.
  @visibleForTesting
  static double? parseImdb(Map<dynamic, dynamic> body) {
    final v = double.tryParse('${body['imdbRating'] ?? ''}');
    return v != null && v > 0 && v <= 10 ? v : null;
  }

  /// The Tomatometer (0..100) from an OMDb title payload, or null.
  @visibleForTesting
  static int? parseRottenTomatoes(Map<dynamic, dynamic> body) {
    final ratings = body['Ratings'];
    if (ratings is List) {
      for (final raw in ratings) {
        if (raw is! Map) continue;
        if ('${raw['Source']}'.toLowerCase() != 'rotten tomatoes') continue;
        final match = RegExp(r'(\d{1,3})\s*%').firstMatch('${raw['Value']}');
        final value = match == null ? null : int.tryParse(match.group(1)!);
        if (value != null && value >= 0 && value <= 100) return value;
      }
    }
    final meter = int.tryParse('${body['tomatoMeter'] ?? ''}');
    return meter != null && meter >= 0 && meter <= 100 ? meter : null;
  }

  void _store(String imdbId, OmdbCacheEntry entry) {
    _cache.remove(imdbId);
    _cache[imdbId] = entry;
    while (_cache.length > _maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    _scheduleSave();
    final listeners = _listeners[imdbId];
    if (listeners == null) return;
    for (final listener in listeners.toList()) {
      listener();
    }
  }

  Future<void> _ensureLoaded() => _loading ??= () async {
    try {
      final prefs = await _prefs();
      final raw = prefs.getString(_prefsKey);
      if (raw != null) {
        final decoded = jsonDecode(raw);
        if (decoded is Map) {
          // Oldest first, so LRU eviction in [_store] drops the right end.
          final entries = <String, OmdbCacheEntry>{};
          decoded.forEach((key, value) {
            if (key is! String) return;
            final entry = OmdbCacheEntry.fromJson(value);
            if (entry != null) entries[key] = entry;
          });
          final sorted = entries.entries.toList()
            ..sort((a, b) => a.value.at.compareTo(b.value.at));
          for (final e in sorted) {
            _cache.putIfAbsent(e.key, () => e.value);
          }
        }
      }
      final rawSeasons = prefs.getString(_seasonPrefsKey);
      if (rawSeasons != null) {
        final decoded = jsonDecode(rawSeasons);
        if (decoded is Map) {
          final entries = <String, OmdbSeasonEntry>{};
          decoded.forEach((key, value) {
            if (key is! String) return;
            final entry = OmdbSeasonEntry.fromJson(value);
            if (entry != null) entries[key] = entry;
          });
          final sorted = entries.entries.toList()
            ..sort((a, b) => a.value.at.compareTo(b.value.at));
          for (final e in sorted) {
            _seasons.putIfAbsent(e.key, () => e.value);
          }
        }
      }
    } catch (_) {
      // A corrupt cache is just an empty one.
    } finally {
      _loaded = true;
    }
  }();

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 3), () async {
      try {
        final prefs = await _prefs();
        final data = <String, List<int?>>{
          for (final e in _cache.entries) e.key: e.value.toJson(),
        };
        await prefs.setString(_prefsKey, jsonEncode(data));
        await prefs.setString(
          _seasonPrefsKey,
          jsonEncode({
            for (final e in _seasons.entries) e.key: e.value.toJson(),
          }),
        );
      } catch (_) {}
    });
  }
}

/// One cached OMDb answer. Persisted compactly as
/// `[rt|null, fetchedMs, releasedMs|null, ongoing 0/1, metacritic|null,
/// imdb×10|null]`.
@immutable
class OmdbCacheEntry {
  const OmdbCacheEntry({
    required this.score,
    this.metacritic,
    this.imdb,
    required this.at,
    this.released,
    this.ongoing = false,
  });

  /// Rotten Tomatoes Tomatometer, 0..100.
  final int? score;

  /// Metascore, 0..100.
  final int? metacritic;

  /// IMDb rating, 0..10.
  final double? imdb;
  final DateTime at;
  final DateTime? released;
  final bool ongoing;

  bool get isEmpty => score == null && metacritic == null && imdb == null;

  List<int?> toJson() => [
    score,
    at.millisecondsSinceEpoch,
    released?.millisecondsSinceEpoch,
    ongoing ? 1 : 0,
    metacritic,
    imdb == null ? null : (imdb! * 10).round(),
  ];

  static OmdbCacheEntry? fromJson(Object? value) {
    if (value is! List || value.length < 2) return null;
    int? intAt(int i) =>
        i < value.length && value[i] is int ? value[i] as int : null;
    final score = intAt(0), fetched = intAt(1), released = intAt(2);
    if (fetched == null) return null;
    return OmdbCacheEntry(
      score: score != null && score >= 0 && score <= 100 ? score : null,
      at: DateTime.fromMillisecondsSinceEpoch(fetched),
      released: released == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(released),
      ongoing: intAt(3) == 1,
      metacritic: switch (intAt(4)) {
        final v? when v >= 0 && v <= 100 => v,
        _ => null,
      },
      imdb: switch (intAt(5)) {
        final v? when v > 0 && v <= 100 => v / 10,
        _ => null,
      },
    );
  }
}

/// One cached OMDb season: IMDb rating per episode number.
@immutable
class OmdbSeasonEntry {
  const OmdbSeasonEntry({
    required this.ratings,
    required this.at,
    this.lastAired,
    this.airing = false,
  });

  final Map<int, double> ratings;
  final DateTime at;
  final DateTime? lastAired;

  /// Some episode is unreleased or undated — the season is still going.
  final bool airing;

  Map<String, Object?> toJson() => {
    'r': {for (final e in ratings.entries) '${e.key}': e.value},
    'at': at.millisecondsSinceEpoch,
    'last': lastAired?.millisecondsSinceEpoch,
    'airing': airing ? 1 : 0,
  };

  static OmdbSeasonEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    final at = value['at'];
    if (at is! int) return null;
    final ratings = <int, double>{};
    final raw = value['r'];
    if (raw is Map) {
      raw.forEach((k, v) {
        final n = int.tryParse('$k');
        if (n != null && v is num) ratings[n] = v.toDouble();
      });
    }
    final last = value['last'];
    return OmdbSeasonEntry(
      ratings: ratings,
      at: DateTime.fromMillisecondsSinceEpoch(at),
      lastAired: last is int ? DateTime.fromMillisecondsSinceEpoch(last) : null,
      airing: value['airing'] == 1,
    );
  }
}
