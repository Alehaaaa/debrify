import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';

import 'mdblist/mdblist_models.dart';
import 'mdblist/mdblist_service.dart';
import 'profiles/profile_preferences.dart';
import 'simkl/simkl_service.dart';
import 'trakt/trakt_service.dart';

/// Durable, per-profile retry queue for playback progress that could not be
/// delivered while offline. Entries are coalesced per tracker/title/episode;
/// a final stop always wins over an older checkpoint.
class TrackerScrobbleOutbox {
  TrackerScrobbleOutbox._();
  static final instance = TrackerScrobbleOutbox._();
  static const _key = 'tracker_scrobble_outbox_v1';
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  bool _flushing = false;

  void initialize() {
    _connectivity ??= Connectivity().onConnectivityChanged.listen((states) {
      if (!states.contains(ConnectivityResult.none)) unawaited(flush());
    });
    unawaited(flush());
  }

  Future<void> enqueue({
    required String tracker,
    required String action,
    required String imdbId,
    required double progress,
    required String? contentType,
    int? season,
    int? episode,
  }) async {
    initialize();
    final prefs = await ProfilePreferences.instance();
    final values = _read(prefs.getString(_key));
    final key = '$tracker|$imdbId|${season ?? ''}|${episode ?? ''}';
    final next = <String, dynamic>{
      'tracker': tracker, 'action': action, 'imdbId': imdbId,
      'progress': progress, 'contentType': contentType,
      'season': season, 'episode': episode,
    };
    final index = values.indexWhere((e) => e['key'] == key);
    // A stop represents the authoritative final state; never replace it with
    // an older/lower-priority heartbeat after reconnecting.
    if (index >= 0 && values[index]['action'] == 'stop' && action != 'stop') {
      return;
    }
    next['key'] = key;
    if (index >= 0) {
      values[index] = next;
    } else {
      values.add(next);
    }
    await prefs.setString(_key, jsonEncode(values));
  }

  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final prefs = await ProfilePreferences.instance();
      final values = _read(prefs.getString(_key));
      final remaining = <Map<String, dynamic>>[];
      for (final entry in values) {
        final ok = switch (entry['tracker']) {
          'trakt' => await _sendTrakt(entry),
          'mdblist' => await _sendMdblist(entry),
          _ => await _sendSimkl(entry),
        };
        if (!ok) remaining.add(entry);
      }
      await prefs.setString(_key, jsonEncode(remaining));
    } catch (_) {
      // The entry remains on disk for the next connectivity/app-start retry.
    } finally { _flushing = false; }
  }

  List<Map<String, dynamic>> _read(String? raw) {
    try {
      final decoded = jsonDecode(raw ?? '[]') as List;
      return decoded.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    } catch (_) { return []; }
  }

  Future<bool> _sendTrakt(Map<String, dynamic> e) => switch (e['action']) {
    'start' => TraktService.instance.scrobbleStart(e['imdbId'], (e['progress'] as num).toDouble(), season: e['season'], episode: e['episode'], contentType: e['contentType'], queueOnFailure: false),
    'pause' => TraktService.instance.scrobblePause(e['imdbId'], (e['progress'] as num).toDouble(), season: e['season'], episode: e['episode'], contentType: e['contentType'], queueOnFailure: false),
    _ => TraktService.instance.scrobbleStop(e['imdbId'], (e['progress'] as num).toDouble(), season: e['season'], episode: e['episode'], contentType: e['contentType'], queueOnFailure: false),
  };
  Future<bool> _sendMdblist(Map<String, dynamic> e) async {
    final ids = MdblistMediaIds.forContent(e['imdbId'] as String);
    final season = e['season'] as int?;
    final episode = e['episode'] as int?;
    final target = season != null && episode != null
        ? MdblistScrobbleTarget.episode(ids, season: season, episode: episode)
        : MdblistScrobbleTarget.movie(ids);
    final progress = (e['progress'] as num).toDouble();
    final service = MdblistService.instance;
    final result = await switch (e['action']) {
      'start' => service.scrobbleStart(target, progress, queueOnFailure: false),
      'pause' => service.scrobblePause(target, progress, queueOnFailure: false),
      _ => service.scrobbleStop(target, progress, queueOnFailure: false),
    };
    // Stay queued only while still unreachable; MDBList refusing the entry
    // (title unknown, account disconnected) would otherwise retry forever.
    if (result.isSuccess) return true;
    final states = await Connectivity().checkConnectivity();
    return !states.every((s) => s == ConnectivityResult.none);
  }

  Future<bool> _sendSimkl(Map<String, dynamic> e) => switch (e['action']) {
    'start' => SimklService.instance.scrobbleStart(e['imdbId'], (e['progress'] as num).toDouble(), season: e['season'], episode: e['episode'], queueOnFailure: false),
    'pause' => SimklService.instance.scrobblePause(e['imdbId'], (e['progress'] as num).toDouble(), season: e['season'], episode: e['episode'], queueOnFailure: false),
    _ => SimklService.instance.scrobbleStop(e['imdbId'], (e['progress'] as num).toDouble(), season: e['season'], episode: e['episode'], queueOnFailure: false),
  };
}
