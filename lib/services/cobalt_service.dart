import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class CobaltMedia {
  const CobaltMedia(this.url, this.instance, {this.expiresAt});
  final String url;
  final Uri instance;

  /// When the instance stops accepting requests for [url]. Tunnels are live
  /// remuxes (no byte ranges) that a player may re-request only until then;
  /// an already-open connection keeps streaming past it.
  final DateTime? expiresAt;
}

class _InstanceHealth {
  _InstanceHealth(this.endpoint);
  final Uri endpoint;
  double latencyMs = double.infinity;
  DateTime? checkedAt;
  DateTime? unavailableUntil;
  bool usable = false;
}

/// Public community endpoints listed without Turnstile on cobalt.directory.
/// Health is checked on the user's connection; directory scores are not used
/// as a substitute for runtime availability. Never supplies cookies, solves
/// challenges, impersonates a frontend, or calls protected session endpoints.
class CobaltService {
  CobaltService({
    http.Client Function()? clientFactory,
    List<Uri>? instances,
    DateTime Function()? now,
  }) : _clientFactory = clientFactory ?? http.Client.new,
       _now = now ?? DateTime.now,
       _instances = (instances ?? publicInstances)
           .map(_InstanceHealth.new)
           .toList();

  static final instance = CobaltService();
  static final publicInstances = <Uri>[
    Uri.parse('https://rue-cobalt.xenon.zone/'),
    Uri.parse('https://cobaltapi.cjs.nz/'),
  ];
  final http.Client Function() _clientFactory;
  final DateTime Function() _now;
  final List<_InstanceHealth> _instances;
  Future<void>? _checking;
  static const _healthTtl = Duration(minutes: 10);

  /// Videos no instance could serve (YouTube refused the instance, or its
  /// tunnel came back empty). Not retried for a while: every attempt costs
  /// rate-limited requests on shared public servers.
  final Map<String, DateTime> _videoMisses = {};
  static const _videoMissTtl = Duration(minutes: 10);

  /// Errors about this video on this instance (YouTube asked the instance to
  /// sign in, the format or content is unavailable, its fetch failed). The
  /// instance stays usable for other videos.
  static bool _isVideoError(String? code) =>
      code != null &&
      (code.startsWith('error.api.youtube.') ||
          code.startsWith('error.api.content.') ||
          code.startsWith('error.api.fetch.'));

  /// A tunnel is a live remux the instance starts on request. When YouTube
  /// blocks the instance mid-way it still answers 200 with an empty body, so
  /// read the first bytes (an MP4 `ftyp`) before handing it to a player.
  /// Null when the probe itself failed (timeout, dropped connection): that
  /// says nothing about the video.
  Future<bool?> _streams(Uri url) async {
    final client = _clientFactory();
    try {
      return await (() async {
        final request = http.Request('GET', url)
          ..headers['Range'] = 'bytes=0-1023';
        final response = await client.send(request);
        if (response.statusCode != 200 && response.statusCode != 206) {
          return false;
        }
        final head = <int>[];
        await for (final chunk in response.stream) {
          head.addAll(chunk);
          if (head.length >= 8) break;
        }
        return head.length >= 8 &&
            String.fromCharCodes(head.sublist(4, 8)) == 'ftyp';
      })().timeout(const Duration(seconds: 8));
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  Future<http.Response> _request(Uri url, {Map<String, Object>? body}) async {
    final client = _clientFactory();
    try {
      return await (() async {
        final request = http.Request(body == null ? 'GET' : 'POST', url)
          ..followRedirects = false
          ..headers['Accept'] = 'application/json';
        if (body != null) {
          request.headers['Content-Type'] = 'application/json';
          request.body = jsonEncode(body);
        }
        final response = await client.send(request);
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          bytes.addAll(chunk);
          if (bytes.length > 128 * 1024) {
            throw const FormatException('Oversized Cobalt response');
          }
        }
        return http.Response.bytes(
          bytes,
          response.statusCode,
          headers: response.headers,
        );
      })().timeout(Duration(seconds: body == null ? 3 : 8));
    } finally {
      client.close();
    }
  }

  void _unavailable(
    _InstanceHealth item, {
    Duration duration = const Duration(minutes: 5),
  }) {
    item.usable = false;
    item.unavailableUntil = _now().add(duration);
  }

  Duration _retryDelay(String? value) {
    final seconds = int.tryParse(value ?? '');
    Duration? delay = seconds == null ? null : Duration(seconds: seconds);
    if (delay == null && value != null) {
      // Retry-After also accepts an RFC 1123 HTTP date.
      final parts = value.split(' ');
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      try {
        if (parts.length == 6 &&
            months.contains(parts[2]) &&
            parts[5] == 'GMT') {
          final time = parts[4].split(':').map(int.parse).toList();
          delay = DateTime.utc(
            int.parse(parts[3]),
            months.indexOf(parts[2]) + 1,
            int.parse(parts[1]),
            time[0],
            time[1],
            time[2],
          ).difference(_now());
        }
      } catch (_) {
        /* Use conservative backoff for malformed headers. */
      }
    }
    delay ??= const Duration(minutes: 5);
    return delay < const Duration(seconds: 30)
        ? const Duration(seconds: 30)
        : delay;
  }

  Future<void> _check(_InstanceHealth item) async {
    final now = _now();
    if (item.unavailableUntil?.isAfter(now) == true) return;
    if (item.usable &&
        item.checkedAt != null &&
        now.difference(item.checkedAt!) < _healthTtl) {
      return;
    }
    final timer = Stopwatch()..start();
    item.checkedAt = now;
    try {
      final response = await _request(item.endpoint);
      if (response.statusCode != 200) {
        final rest = response.statusCode == 429
            ? _retryDelay(response.headers['retry-after'])
            : const Duration(minutes: 5);
        debugPrint(
          'Cobalt: ${item.endpoint.host} health HTTP ${response.statusCode}, '
          'resting ${rest.inSeconds}s',
        );
        _unavailable(item, duration: rest);
        return;
      }
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      final info = data is Map ? data['cobalt'] : null;
      if (info is! Map ||
          info['services'] is! List ||
          !(info['services'] as List).contains('youtube') ||
          (info['turnstileSitekey']?.toString().isNotEmpty ?? false)) {
        _unavailable(item);
        return;
      }
      item.usable = true;
      final elapsed = timer.elapsedMilliseconds.toDouble();
      item.latencyMs = item.latencyMs.isFinite
          ? item.latencyMs * .5 + elapsed * .5
          : elapsed;
    } catch (e) {
      // A slow or dropped health check is usually a moment's hiccup, not a
      // dead instance: rest briefly so it is back for the next clip.
      debugPrint('Cobalt: ${item.endpoint.host} health check failed — $e');
      _unavailable(item, duration: _transientRest);
    }
  }

  static const _transientRest = Duration(seconds: 30);

  /// Whether [videoId] was recently refused by every instance, so a relay
  /// miss for it is a real answer rather than an instance being out of
  /// rotation (rate-limited, timing out) at that moment.
  bool knowsUnservable(String videoId) =>
      _videoMisses[videoId]?.isAfter(_now()) ?? false;

  Future<void> _refresh() async {
    if (_checking case final active?) {
      await active;
      return;
    }
    final run = Future.wait(_instances.map(_check)).then((_) {});
    _checking = run;
    try {
      await run;
    } finally {
      if (identical(_checking, run)) _checking = null;
    }
  }

  /// Rank by measured latency and send the video only to the selected instance.
  /// Do not race media requests across a fleet of public servers.
  Future<CobaltMedia?> resolve(String videoId, {required int maxHeight}) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]{11}$').hasMatch(videoId)) return null;
    final missUntil = _videoMisses[videoId];
    if (missUntil != null) {
      if (missUntil.isAfter(_now())) return null;
      _videoMisses.remove(videoId);
    }
    await _refresh();
    final candidates =
        _instances
            .where(
              (item) =>
                  item.usable && item.unavailableUntil?.isAfter(_now()) != true,
            )
            .toList()
          ..sort((a, b) => a.latencyMs.compareTo(b.latencyMs));
    const heights = [1080, 720, 480, 360, 240, 144];
    final height = heights.firstWhere((h) => h <= maxHeight, orElse: () => 144);
    for (final item in _instances) {
      if (candidates.contains(item)) continue;
      final until = item.unavailableUntil;
      final rest = until?.difference(_now()).inSeconds;
      debugPrint(
        'Cobalt: ${item.endpoint.host} skipped for $videoId'
        '${rest == null ? ' (unhealthy)' : ' (resting ${rest}s)'}',
      );
    }
    // Only a refusal from every instance is a real answer about the video.
    var videoRefusals = 0;
    for (final item in candidates) {
      if (!item.usable || item.unavailableUntil?.isAfter(_now()) == true) {
        debugPrint('Cobalt: ${item.endpoint.host} skipped for $videoId');
        continue;
      }
      final timer = Stopwatch()..start();
      try {
        final response = await _request(
          item.endpoint,
          body: {
            'url': 'https://www.youtube.com/watch?v=$videoId',
            'videoQuality': '$height',
            'youtubeVideoCodec': 'h264',
            'downloadMode': 'auto',
            'localProcessing': 'disabled',
          },
        );
        if (response.statusCode == 429) {
          final rest = _retryDelay(response.headers['retry-after']);
          debugPrint(
            'Cobalt: ${item.endpoint.host} rate-limited, resting '
            '${rest.inSeconds}s (skipped for $videoId)',
          );
          _unavailable(item, duration: rest);
          continue;
        }
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final error = data is Map ? data['error'] : null;
        final code = error is Map ? error['code']?.toString() : null;
        if (_isVideoError(code)) {
          // This video/format failed, not the public instance as a whole.
          debugPrint('Cobalt: ${item.endpoint.host} cannot serve $videoId ($code)');
          videoRefusals++;
          continue;
        }
        if (response.statusCode != 200) {
          debugPrint(
            'Cobalt: ${item.endpoint.host} unavailable '
            '(HTTP ${response.statusCode}${code == null ? '' : ', $code'})',
          );
          _unavailable(item);
          continue;
        }
        if (data is! Map || !{'tunnel', 'redirect'}.contains(data['status'])) {
          debugPrint(
            'Cobalt: ${item.endpoint.host} unexpected response for $videoId',
          );
          _unavailable(item);
          continue;
        }
        final url = Uri.tryParse(data['url']?.toString() ?? '');
        // No local-network URLs, credentials, or unrelated redirect domains.
        if (url == null ||
            url.scheme != 'https' ||
            url.userInfo.isNotEmpty ||
            !(url.origin == item.endpoint.origin ||
                url.host.endsWith('.googlevideo.com'))) {
          _unavailable(item);
          continue;
        }
        final expiresMs = int.tryParse(url.queryParameters['exp'] ?? '');
        final expiresSeconds = int.tryParse(
          url.queryParameters['expire'] ?? '',
        );
        final expires =
            expiresMs ??
            (expiresSeconds == null ? null : expiresSeconds * 1000);
        if (expires != null &&
            expires <= _now().millisecondsSinceEpoch + 30000) {
          // Reject an already expired/nearly expired URL before first playback,
          // not just when it is later considered for cache reuse.
          _unavailable(item, duration: const Duration(seconds: 30));
          continue;
        }
        final elapsed = timer.elapsedMilliseconds.toDouble();
        final streams = await _streams(url);
        if (streams == null) {
          debugPrint(
            'Cobalt: ${item.endpoint.host} stream probe timed out for $videoId',
          );
          continue;
        }
        if (!streams) {
          debugPrint('Cobalt: ${item.endpoint.host} sent an empty stream for $videoId');
          videoRefusals++;
          continue;
        }
        item.latencyMs = item.latencyMs.isFinite
            ? item.latencyMs * .3 + elapsed * .7
            : elapsed;
        debugPrint('Cobalt: $videoId via ${item.endpoint.host} (${height}p)');
        return CobaltMedia(
          url.toString(),
          item.endpoint,
          expiresAt: expires == null
              ? null
              : DateTime.fromMillisecondsSinceEpoch(expires),
        );
      } catch (e) {
        debugPrint(
          'Cobalt: ${item.endpoint.host} failed for $videoId — $e '
          '(resting ${_transientRest.inSeconds}s)',
        );
        _unavailable(item, duration: _transientRest);
      }
    }
    if (videoRefusals == _instances.length) {
      _videoMisses[videoId] = _now().add(_videoMissTtl);
      while (_videoMisses.length > 256) {
        _videoMisses.remove(_videoMisses.keys.first);
      }
    }
    return null;
  }
}
