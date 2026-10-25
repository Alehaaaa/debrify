import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../models/torbox_torrent.dart';
import '../models/torbox_user.dart';
import '../models/torbox_web_download.dart';
import '../utils/json_isolate.dart';

/// TorBox rejected this account for a write/read required by playback. A
/// cachedness result does not grant permission to create a torrent. Never put
/// the response body, request URL, token or magnet into this exception.
class TorboxAuthorizationException implements Exception {
  const TorboxAuthorizationException({required this.statusCode});
  final int statusCode;

  @override
  String toString() =>
      'TorBox authorization failed ($statusCode). Check the TorBox account, API key and account permissions in Settings.';
}

/// Only network/availability failures, never a claim that the API key is bad.
/// Callers may show a reconnect/retry state instead of a sign-in error.
enum TorboxConnectionFailureKind { timeout, network, server, rateLimited }

class TorboxConnectionException implements Exception {
  const TorboxConnectionException(this.kind, {this.statusCode});
  final TorboxConnectionFailureKind kind;
  final int? statusCode;

  @override
  String toString() => switch (kind) {
    TorboxConnectionFailureKind.timeout =>
      'TorBox request timed out. Check connectivity or retry later.',
    TorboxConnectionFailureKind.network =>
      'Unable to connect to TorBox. Check connectivity or retry later.',
    TorboxConnectionFailureKind.server =>
      'TorBox is temporarily unavailable (${statusCode ?? 500}). Retry later.',
    TorboxConnectionFailureKind.rateLimited =>
      'TorBox rate limit reached (429). Retry later.',
  };
}

enum TorboxRequestFailureKind { apiError, invalidResponse, notFound }

class TorboxRequestException implements Exception {
  const TorboxRequestException(this.kind, {this.statusCode});
  final TorboxRequestFailureKind kind;
  final int? statusCode;

  @override
  String toString() => switch (kind) {
    TorboxRequestFailureKind.apiError =>
      'TorBox rejected the request (${statusCode ?? 'API error'}).',
    TorboxRequestFailureKind.invalidResponse =>
      'TorBox returned an invalid response.',
    TorboxRequestFailureKind.notFound => 'TorBox file was not found (404).',
  };
}

/// Caps GET replay AND total wall-clock time. Timeout covers response body
/// completion as well as initial headers, not just the socket handshake.
@immutable
class TorboxReadRetryPolicy {
  const TorboxReadRetryPolicy({
    this.maxAttempts = 2,
    this.perAttemptTimeout = const Duration(seconds: 7),
    this.totalDeadline = const Duration(seconds: 16),
    this.retryDelay = const Duration(milliseconds: 250),
  });

  final int maxAttempts;
  final Duration perAttemptTimeout;
  final Duration totalDeadline;
  final Duration retryDelay;
}

class TorboxService {
  static const String _baseUrl = 'https://api.torbox.app/v1/api';

  /// One-shot injectable GET transport for deterministic tests. Production
  /// performs a no-follow redirect request and closes the client on timeout.
  @visibleForTesting
  static Future<http.Response> Function(http.Request request)?
  debugReadTransport;

  static Future<http.Response> _readOnce(
    Uri uri,
    Map<String, String> headers,
    Duration timeout,
  ) async {
    final request = http.Request('GET', uri)
      ..headers.addAll(headers)
      ..followRedirects = false;
    final mock = debugReadTransport;
    if (mock != null) return mock(request).timeout(timeout);
    final client = http.Client();
    try {
      return await client
          .send(request)
          .then(http.Response.fromStream)
          .timeout(timeout);
    } finally {
      client.close();
    }
  }

  /// One bounded retry for safe GETs only. No POST/delete operation calls this.
  /// A timeout/HTTP 5xx/short 429 is transient; auth never retries. Requests
  /// never leak token-bearing URIs or upstream body text to diagnostics.
  static Future<http.Response> _readWithRetry(
    Uri uri,
    Map<String, String> headers, {
    TorboxReadRetryPolicy policy = const TorboxReadRetryPolicy(),
  }) async {
    final started = DateTime.now();
    var attempt = 0;
    while (true) {
      attempt++;
      final remaining =
          policy.totalDeadline - DateTime.now().difference(started);
      if (remaining <= Duration.zero) {
        throw const TorboxConnectionException(
          TorboxConnectionFailureKind.timeout,
        );
      }
      final singleTimeout = remaining < policy.perAttemptTimeout
          ? remaining
          : policy.perAttemptTimeout;
      TorboxConnectionException? transient;
      Duration? retryAfter;
      try {
        final response = await _readOnce(uri, headers, singleTimeout);
        if (isAuthorizationFailure(response.statusCode, null)) {
          throw TorboxAuthorizationException(statusCode: response.statusCode);
        }
        if (response.statusCode == 429) {
          transient = const TorboxConnectionException(
            TorboxConnectionFailureKind.rateLimited,
            statusCode: 429,
          );
          final delaySeconds = int.tryParse(
            response.headers['retry-after']?.trim() ?? '',
          );
          // A long server Retry-After belongs to a later user-initiated retry,
          // not a screen-blocking loop.
          retryAfter = delaySeconds == null
              ? policy.retryDelay
              : Duration(seconds: delaySeconds);
        } else if (response.statusCode >= 500) {
          transient = TorboxConnectionException(
            TorboxConnectionFailureKind.server,
            statusCode: response.statusCode,
          );
        } else {
          return response;
        }
      } on TorboxAuthorizationException {
        rethrow;
      } on TimeoutException {
        transient = const TorboxConnectionException(
          TorboxConnectionFailureKind.timeout,
        );
      } on SocketException {
        transient = const TorboxConnectionException(
          TorboxConnectionFailureKind.network,
        );
      } on http.ClientException {
        transient = const TorboxConnectionException(
          TorboxConnectionFailureKind.network,
        );
      } on TorboxConnectionException {
        rethrow;
      } on Exception {
        // Raw transport errors can carry the token-bearing request URI.
        transient = const TorboxConnectionException(
          TorboxConnectionFailureKind.network,
        );
      }
      final pause = retryAfter ?? policy.retryDelay;
      final budget = policy.totalDeadline - DateTime.now().difference(started);
      if (attempt >= policy.maxAttempts ||
          pause > const Duration(seconds: 1) ||
          budget <= pause) {
        throw transient;
      }
      debugPrint(
        'TorboxService: transient GET ${transient.kind.name}; '
        'retrying once (attempt $attempt)',
      );
      if (pause > Duration.zero) await Future<void>.delayed(pause);
    }
  }

  /// The provider sometimes returns HTTP 200/400 with AUTH_ERROR in JSON.
  /// Inspect only the fixed error code, never log raw payloads or bearer tokens.
  @visibleForTesting
  static bool isAuthorizationFailure(int status, Object? payload) {
    if (status == 401 || status == 403) return true;
    if (payload is! Map) return false;
    final error = payload['error'];
    final code = error is Map
        ? (error['code'] ?? error['error'] ?? error['type'])
        : error;
    final normalized = code?.toString().trim().toUpperCase() ?? '';
    return normalized == 'AUTH_ERROR' ||
        normalized == 'INVALID_TOKEN' ||
        normalized == 'INVALID_API_KEY' ||
        normalized == 'UNAUTHORIZED' ||
        normalized == 'FORBIDDEN';
  }

  /// A transport seam for deterministic 403 regression tests; production uses
  /// MultipartRequest.send. Scoped to createTorrent, never used to skip auth.
  @visibleForTesting
  static Future<http.StreamedResponse> Function(http.MultipartRequest)?
  debugCreateTorrentTransport;

  static Future<TorboxUser> getUserInfo(
    String apiKey, {
    TorboxReadRetryPolicy retryPolicy = const TorboxReadRetryPolicy(
      perAttemptTimeout: Duration(seconds: 10),
      totalDeadline: Duration(seconds: 22),
    ),
  }) async {
    final uri = Uri.parse('$_baseUrl/user/me?settings=false');
    try {
      debugPrint('TorboxService: Requesting user info…');
      final headers = {
        'Authorization': _formatAuthHeader(apiKey),
        'Content-Type': 'application/json',
      };
      // Credential never appears in the diagnostic stream.
      final response = await _readWithRetry(uri, headers, policy: retryPolicy);

      if (response.statusCode != 200) {
        debugPrint('TorboxService: Unexpected status ${response.statusCode}');
        if (isAuthorizationFailure(response.statusCode, null)) {
          throw TorboxAuthorizationException(statusCode: response.statusCode);
        }
        throw Exception('Failed to fetch user info: ${response.statusCode}');
      }

      final Map<String, dynamic> payload =
          await decodeJsonAsync(response.body) as Map<String, dynamic>;
      final bool success = payload['success'] as bool? ?? false;
      if (!success) {
        if (isAuthorizationFailure(response.statusCode, payload)) {
          throw TorboxAuthorizationException(statusCode: response.statusCode);
        }
        debugPrint('TorboxService: User info rejected by provider');
        throw Exception('Torbox API returned an error');
      }

      final data = payload['data'];
      if (data is Map<String, dynamic>) {
        debugPrint('TorboxService: User info retrieved successfully.');
        return TorboxUser.fromJson(data);
      }

      debugPrint('TorboxService: Unexpected user info payload structure');
      throw Exception('Unexpected response format from Torbox');
    } on TorboxAuthorizationException {
      rethrow;
    } on TorboxConnectionException {
      rethrow;
    } catch (e) {
      debugPrint('TorboxService: Request failed (${e.runtimeType})');
      throw Exception('Torbox user info request failed');
    }
  }

  static Future<Map<String, dynamic>> getTorrents(
    String apiKey, {
    int offset = 0,
    int limit = 50,
    int? torrentId,
    TorboxReadRetryPolicy retryPolicy = const TorboxReadRetryPolicy(
      perAttemptTimeout: Duration(seconds: 8),
      totalDeadline: Duration(seconds: 18),
    ),
  }) async {
    final queryParameters = <String, String>{'bypass_cache': 'true'};
    if (torrentId != null) {
      queryParameters['id'] = '$torrentId';
    } else {
      queryParameters['offset'] = '$offset';
      queryParameters['limit'] = '$limit';
    }

    final uri = Uri.parse(
      '$_baseUrl/torrents/mylist',
    ).replace(queryParameters: queryParameters);

    try {
      if (torrentId != null) {
        debugPrint('TorboxService: Fetching torrent id=$torrentId');
      } else {
        debugPrint(
          'TorboxService: Fetching torrents offset=$offset limit=$limit',
        );
      }
      final headers = {
        'Authorization': _formatAuthHeader(apiKey),
        'Content-Type': 'application/json',
      };

      final response = await _readWithRetry(uri, headers, policy: retryPolicy);

      if (response.statusCode != 200) {
        debugPrint(
          'TorboxService: Torrent fetch status ${response.statusCode}',
        );
        if (isAuthorizationFailure(response.statusCode, null)) {
          throw TorboxAuthorizationException(statusCode: response.statusCode);
        }
        throw Exception('Failed to fetch torrents: ${response.statusCode}');
      }

      final Map<String, dynamic> payload =
          await decodeJsonAsync(response.body) as Map<String, dynamic>;
      final bool success = payload['success'] as bool? ?? false;
      if (!success) {
        if (isAuthorizationFailure(response.statusCode, payload)) {
          throw TorboxAuthorizationException(statusCode: response.statusCode);
        }
        debugPrint('TorboxService: Torrent fetch rejected by provider');
        throw Exception('Torbox API returned an error');
      }

      final data = payload['data'];
      if (torrentId != null) {
        if (data is Map<String, dynamic>) {
          final torrent = TorboxTorrent.fromJson(data);
          if (!torrent.isCachedOrCompleted) {
            debugPrint(
              'TorboxService: Torrent $torrentId not cached/completed yet',
            );
            return {
              'torrents': <TorboxTorrent>[],
              'hasMore': false,
              'torrent': null,
            };
          }
          return {
            'torrents': <TorboxTorrent>[torrent],
            'hasMore': false,
            'torrent': torrent,
          };
        }
        if (data is List) {
          final rawList = data.whereType<Map<String, dynamic>>().toList();
          final torrents = rawList
              .map(TorboxTorrent.fromJson)
              .where((torrent) => torrent.isCachedOrCompleted)
              .toList();
          final torrent = torrents.isNotEmpty ? torrents.first : null;
          return {'torrents': torrents, 'hasMore': false, 'torrent': torrent};
        }
      }

      if (data is List) {
        final rawList = data.whereType<Map<String, dynamic>>().toList();
        final torrents = rawList
            .map(TorboxTorrent.fromJson)
            .where((torrent) => torrent.isCachedOrCompleted)
            .toList();
        final bool hasMore =
            torrentId == null && rawList.length == limit && rawList.isNotEmpty;
        debugPrint(
          'TorboxService: Retrieved ${torrents.length} cached torrents (raw=${rawList.length}). hasMore=$hasMore',
        );
        return {
          'torrents': torrents,
          'hasMore': hasMore,
          'torrent': torrents.isNotEmpty ? torrents.first : null,
        };
      }

      debugPrint('TorboxService: Unexpected torrent payload structure');
      throw Exception('Unexpected response format from Torbox');
    } on TorboxAuthorizationException {
      rethrow;
    } on TorboxConnectionException {
      rethrow;
    } catch (e) {
      debugPrint('TorboxService: Torrent request failed (${e.runtimeType})');
      throw Exception('Torbox torrent request failed');
    }
  }

  static Future<Set<String>> checkCachedTorrents({
    required String apiKey,
    required List<String> infoHashes,
    bool listFiles = false,
  }) async {
    if (infoHashes.isEmpty) return const <String>{};

    final headers = {
      'Authorization': _formatAuthHeader(apiKey),
      'Content-Type': 'application/json',
    };

    final sanitized = infoHashes
        .map((hash) => hash.trim().toLowerCase())
        .where((hash) => hash.isNotEmpty)
        .toSet()
        .toList();

    const int chunkSize = 90;
    const int maxConcurrent = 20;
    final Set<String> cached = <String>{};

    Future<void> processChunk(int start) async {
      final chunk = sanitized.sublist(
        start,
        math.min(start + chunkSize, sanitized.length),
      );

      final querySegments = <String>[
        'format=list',
        'list_files=${listFiles ? 'true' : 'false'}',
        ...chunk.map((hash) => 'hash=${Uri.encodeQueryComponent(hash)}'),
      ];
      final uri = Uri.parse(
        '$_baseUrl/torrents/checkcached?${querySegments.join('&')}',
      );

      try {
        debugPrint(
          'TorboxService: Checking cache for ${chunk.length} torrents (chunk start=$start)',
        );
        final response = await http
            .get(uri, headers: headers)
            .timeout(const Duration(seconds: 60));

        if (response.statusCode != 200) {
          debugPrint(
            'TorboxService: checkcached status ${response.statusCode}',
          );
          throw Exception(
            'Failed to check Torbox cache: ${response.statusCode}',
          );
        }

        final Map<String, dynamic> payload =
            await decodeJsonAsync(response.body) as Map<String, dynamic>;
        final bool success = payload['success'] as bool? ?? false;
        if (!success) {
          debugPrint('TorboxService: checkcached provider error');
          throw Exception('Torbox cache check failed');
        }

        final data = payload['data'];
        if (data is List) {
          for (final entry in data) {
            if (entry is Map<String, dynamic>) {
              final hash = (entry['hash'] as String?)?.trim().toLowerCase();
              if (hash != null && hash.isNotEmpty) {
                cached.add(hash);
              }
            }
          }
        }
      } catch (e) {
        debugPrint(
          'TorboxService: checkcached chunk failed (${e.runtimeType})',
        );
      }
    }

    final futures = <Future<void>>[];
    for (int start = 0; start < sanitized.length; start += chunkSize) {
      futures.add(processChunk(start));
      if (futures.length == maxConcurrent) {
        await Future.wait(futures);
        futures.clear();
      }
    }
    if (futures.isNotEmpty) {
      await Future.wait(futures);
    }

    debugPrint('TorboxService: Cached hashes found ${cached.length}');
    return cached;
  }

  static String createZipPermalink(String apiKey, int torrentId) {
    final token = _rawApiToken(apiKey);
    final uri = Uri.parse('$_baseUrl/torrents/requestdl').replace(
      queryParameters: {
        'token': token,
        'torrent_id': '$torrentId',
        'zip_link': 'true',
        'redirect': 'true',
      },
    );
    return uri.toString();
  }

  static Future<Map<String, dynamic>> createTorrent({
    required String apiKey,
    required String magnet,
    bool seed = true,
    bool allowZip = true,
    bool addOnlyIfCached = true,
  }) async {
    final uri = Uri.parse('$_baseUrl/torrents/createtorrent');
    final headers = {'Authorization': _formatAuthHeader(apiKey)};
    final trimmedMagnet = magnet.trim();

    final request = http.MultipartRequest('POST', uri)
      ..headers.addAll(headers)
      ..fields['seed'] = seed ? '1' : '0'
      ..fields['allow_zip'] = allowZip ? 'true' : 'false'
      ..fields['add_only_if_cached'] = addOnlyIfCached ? 'true' : 'false';

    if (trimmedMagnet.toLowerCase().startsWith('http')) {
      final torrentBytes = await _downloadTorrentFile(trimmedMagnet);
      request.files.add(
        http.MultipartFile.fromBytes(
          'file',
          torrentBytes,
          filename: 'debrify.torrent',
        ),
      );
    } else {
      request.fields['magnet'] = trimmedMagnet;
    }

    try {
      debugPrint(
        'TorboxService: createtorrent input=${_safeInputLabel(trimmedMagnet)}',
      );
      final response =
          await (debugCreateTorrentTransport?.call(request) ?? request.send())
              .timeout(const Duration(seconds: 20));
      final body = await response.stream.bytesToString();
      debugPrint('TorboxService: createtorrent status=${response.statusCode}');

      // HTTP auth status is authoritative even if TorBox returns HTML/non-JSON.
      // A valid JSON failure can also use HTTP 200/400 plus AUTH_ERROR.
      Map<String, dynamic>? payload;
      try {
        final decoded = await decodeJsonAsync(body);
        if (decoded is Map<String, dynamic>) payload = decoded;
      } catch (_) {
        // Never echo an HTML response containing a diagnostic token.
      }
      if (isAuthorizationFailure(response.statusCode, payload)) {
        throw TorboxAuthorizationException(statusCode: response.statusCode);
      }

      // For 400 errors, the body contains useful error info (like DOWNLOAD_NOT_CACHED)
      // Return the payload so the caller can check the error field
      if (response.statusCode == 400) {
        return payload ?? const {'success': false, 'error': 'REQUEST_FAILED'};
      }

      // For other non-200 status codes, throw specific errors
      if (response.statusCode != 200) {
        if (response.statusCode == 429) {
          throw Exception(
            'Too many requests to Torbox. Please wait and try again',
          );
        } else if (response.statusCode >= 500) {
          throw Exception('Torbox service is temporarily unavailable');
        }
        throw Exception('Failed to add torrent to Torbox');
      }

      if (payload == null) {
        throw const FormatException('Unexpected TorBox response format');
      }
      return payload;
    } catch (e) {
      debugPrint('TorboxService: createTorrent failed: $e');
      rethrow;
    }
  }

  static String _safeInputLabel(String input) {
    final lower = input.toLowerCase();
    if (lower.startsWith('http://') || lower.startsWith('https://')) {
      return 'torrent_url:<redacted>';
    }
    if (lower.startsWith('magnet:')) return 'magnet:<redacted>';
    return '<redacted>';
  }

  static Future<List<int>> _downloadTorrentFile(String torrentUrl) async {
    final response = await http
        .get(Uri.parse(torrentUrl))
        .timeout(const Duration(seconds: 20));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception(
        'Failed to download torrent file: ${response.statusCode}',
      );
    }
    return response.bodyBytes;
  }

  // Calls for the same credential/torrent/file share one request chain, even
  // when three UI widgets concurrently request the same link. Keys never log
  // or persist; all success and failure paths release their entry.
  static final Map<(String, int, int), Future<String>> _pendingFileLinks = {};

  static Future<String> requestFileDownloadLink({
    required String apiKey,
    required int torrentId,
    required int fileId,
    TorboxReadRetryPolicy retryPolicy = const TorboxReadRetryPolicy(),
  }) async {
    final key = (_rawApiToken(apiKey), torrentId, fileId);
    final current = _pendingFileLinks[key];
    if (current != null) return current;
    final pending = _requestFileDownloadLinkOnce(
      apiKey: apiKey,
      torrentId: torrentId,
      fileId: fileId,
      retryPolicy: retryPolicy,
    );
    _pendingFileLinks[key] = pending;
    try {
      return await pending;
    } finally {
      if (identical(_pendingFileLinks[key], pending)) {
        _pendingFileLinks.remove(key);
      }
    }
  }

  static bool _isSafeDownloadUrl(String url) {
    final parsed = Uri.tryParse(url);
    return parsed != null &&
        parsed.scheme == 'https' &&
        parsed.host.isNotEmpty &&
        parsed.userInfo.isEmpty;
  }

  static Future<String> _requestFileDownloadLinkOnce({
    required String apiKey,
    required int torrentId,
    required int fileId,
    required TorboxReadRetryPolicy retryPolicy,
  }) async {
    final uri = Uri.parse('$_baseUrl/torrents/requestdl').replace(
      queryParameters: {
        // Required by TorBox in addition to the Authorization header. Never
        // log the URL or forward this credential to the returned CDN host.
        'token': _rawApiToken(apiKey),
        'torrent_id': '$torrentId',
        'file_id': '$fileId',
        'zip_link': 'false',
        'redirect': 'false',
      },
    );

    final headers = {
      'Authorization': _formatAuthHeader(apiKey),
      'Content-Type': 'application/json',
    };

    try {
      debugPrint('TorboxService: requestdl torrent=$torrentId file=$fileId');
      final response = await _readWithRetry(uri, headers, policy: retryPolicy);
      debugPrint('TorboxService: requestdl status=${response.statusCode}');
      if (response.statusCode >= 300 && response.statusCode < 400) {
        final redirectUrl = response.headers['location'];
        if (redirectUrl != null && _isSafeDownloadUrl(redirectUrl)) {
          debugPrint('TorboxService: requestdl returned redirect');
          return redirectUrl;
        }
        throw const TorboxRequestException(
          TorboxRequestFailureKind.invalidResponse,
        );
      }

      Map<String, dynamic> payload;
      try {
        final decoded = await decodeJsonAsync(response.body);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Unexpected response type');
        }
        payload = decoded;
      } catch (_) {
        if (response.statusCode == 404) {
          throw const TorboxRequestException(
            TorboxRequestFailureKind.notFound,
            statusCode: 404,
          );
        }
        throw const TorboxRequestException(
          TorboxRequestFailureKind.invalidResponse,
        );
      }
      if (isAuthorizationFailure(response.statusCode, payload)) {
        throw TorboxAuthorizationException(statusCode: response.statusCode);
      }
      if (response.statusCode == 404) {
        throw const TorboxRequestException(
          TorboxRequestFailureKind.notFound,
          statusCode: 404,
        );
      }
      if (response.statusCode != 200) {
        throw TorboxRequestException(
          TorboxRequestFailureKind.apiError,
          statusCode: response.statusCode,
        );
      }
      final bool success = payload['success'] as bool? ?? false;
      if (!success) {
        throw const TorboxRequestException(TorboxRequestFailureKind.apiError);
      }

      final dynamic data = payload['data'];
      if (data is String && _isSafeDownloadUrl(data)) {
        return data;
      }
      throw const TorboxRequestException(
        TorboxRequestFailureKind.invalidResponse,
      );
    } catch (e) {
      debugPrint(
        'TorboxService: requestFileDownloadLink failed '
        '(${e.runtimeType})',
      );
      rethrow;
    }
  }

  static Future<TorboxTorrent?> getTorrentById(
    String apiKey,
    int torrentId, {
    int attempts = 5,
    Duration delayBetweenAttempts = const Duration(milliseconds: 300),
  }) async {
    for (int attempt = 0; attempt < attempts; attempt++) {
      try {
        final result = await getTorrents(apiKey, torrentId: torrentId);
        final TorboxTorrent? torrent =
            result['torrent'] as TorboxTorrent? ??
            _firstTorrent(result['torrents']);
        if (torrent != null) {
          return torrent;
        }
      } on TorboxAuthorizationException {
        rethrow; // A fatal account error must never poll five times.
      } on TorboxConnectionException {
        rethrow; // GET retries are already bounded; avoid 5 nested timeouts.
      } catch (e) {
        debugPrint(
          'TorboxService: getTorrentById attempt ${attempt + 1} failed (${e.runtimeType})',
        );
      }
      if (attempt < attempts - 1) {
        await Future.delayed(delayBetweenAttempts);
      }
    }
    return null;
  }

  static TorboxTorrent? _firstTorrent(dynamic value) {
    if (value is List) {
      for (final item in value) {
        if (item is TorboxTorrent) {
          return item;
        }
      }
    }
    return null;
  }

  // ==================== WEB DOWNLOAD API METHODS ====================

  /// Fetch web downloads list with pagination
  static Future<Map<String, dynamic>> getWebDownloads(
    String apiKey, {
    int offset = 0,
    int limit = 50,
    int? webId,
    TorboxReadRetryPolicy retryPolicy = const TorboxReadRetryPolicy(
      perAttemptTimeout: Duration(seconds: 8),
      totalDeadline: Duration(seconds: 18),
    ),
  }) async {
    final queryParameters = <String, String>{'bypass_cache': 'true'};
    if (webId != null) {
      queryParameters['id'] = '$webId';
    } else {
      queryParameters['offset'] = '$offset';
      queryParameters['limit'] = '$limit';
    }

    final uri = Uri.parse(
      '$_baseUrl/webdl/mylist',
    ).replace(queryParameters: queryParameters);

    try {
      if (webId != null) {
        debugPrint('TorboxService: Fetching web download id=$webId');
      } else {
        debugPrint(
          'TorboxService: Fetching web downloads offset=$offset limit=$limit',
        );
      }
      final headers = {
        'Authorization': _formatAuthHeader(apiKey),
        'Content-Type': 'application/json',
      };

      final response = await _readWithRetry(uri, headers, policy: retryPolicy);

      final Map<String, dynamic> payload;
      try {
        final decoded = await decodeJsonAsync(response.body);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Not an object');
        }
        payload = decoded;
      } catch (_) {
        if (response.statusCode == 404) {
          throw const TorboxRequestException(
            TorboxRequestFailureKind.notFound,
            statusCode: 404,
          );
        }
        throw const TorboxRequestException(
          TorboxRequestFailureKind.invalidResponse,
        );
      }
      if (isAuthorizationFailure(response.statusCode, payload)) {
        throw TorboxAuthorizationException(statusCode: response.statusCode);
      }
      if (response.statusCode != 200) {
        debugPrint(
          'TorboxService: Web download fetch status ${response.statusCode}',
        );
        throw TorboxRequestException(
          response.statusCode == 404
              ? TorboxRequestFailureKind.notFound
              : TorboxRequestFailureKind.apiError,
          statusCode: response.statusCode,
        );
      }
      final bool success = payload['success'] as bool? ?? false;
      if (!success) {
        debugPrint('TorboxService: Web download fetch rejected by provider');
        throw const TorboxRequestException(TorboxRequestFailureKind.apiError);
      }

      final data = payload['data'];
      if (data is List) {
        final rawList = data.whereType<Map<String, dynamic>>().toList();
        final webDownloads = rawList
            .map(TorboxWebDownload.fromJson)
            .where((wd) => wd.isCompleted)
            .toList();
        final bool hasMore =
            webId == null && rawList.length == limit && rawList.isNotEmpty;
        debugPrint(
          'TorboxService: Retrieved ${webDownloads.length} completed web downloads (raw=${rawList.length}). hasMore=$hasMore',
        );
        return {'webDownloads': webDownloads, 'hasMore': hasMore};
      }

      debugPrint('TorboxService: Unexpected web download payload structure');
      throw const TorboxRequestException(
        TorboxRequestFailureKind.invalidResponse,
      );
    } catch (e) {
      debugPrint(
        'TorboxService: Web download request failed '
        '(${e.runtimeType})',
      );
      if (e is TorboxAuthorizationException ||
          e is TorboxConnectionException ||
          e is TorboxRequestException) {
        rethrow;
      }
      // Never interpolate an unexpected exception: HTTP clients can include
      // token-bearing query strings and server data in error messages.
      throw const TorboxRequestException(
        TorboxRequestFailureKind.invalidResponse,
      );
    }
  }

  // The zip flag changes the resource returned; it must participate in the
  // single-flight key. Do not cache a successful signed URL beyond its flight.
  static final Map<(String, int, int, bool), Future<String>>
  _pendingWebFileLinks = {};

  /// Request download link for a web download file. Only the idempotent GET is
  /// replayed, never the create/delete web download operations.
  static Future<String> requestWebDownloadFileLink({
    required String apiKey,
    required int webId,
    required int fileId,
    bool zipLink = false,
    TorboxReadRetryPolicy retryPolicy = const TorboxReadRetryPolicy(),
  }) async {
    final key = (_rawApiToken(apiKey), webId, fileId, zipLink);
    final ongoing = _pendingWebFileLinks[key];
    if (ongoing != null) return ongoing;
    final pending = _requestWebDownloadFileLinkOnce(
      apiKey: apiKey,
      webId: webId,
      fileId: fileId,
      zipLink: zipLink,
      retryPolicy: retryPolicy,
    );
    _pendingWebFileLinks[key] = pending;
    try {
      return await pending;
    } finally {
      if (identical(_pendingWebFileLinks[key], pending)) {
        _pendingWebFileLinks.remove(key);
      }
    }
  }

  static Future<String> _requestWebDownloadFileLinkOnce({
    required String apiKey,
    required int webId,
    required int fileId,
    required bool zipLink,
    required TorboxReadRetryPolicy retryPolicy,
  }) async {
    final uri = Uri.parse('$_baseUrl/webdl/requestdl').replace(
      queryParameters: {
        'token': _rawApiToken(apiKey),
        'web_id': '$webId',
        'file_id': '$fileId',
        'zip_link': zipLink ? 'true' : 'false',
      },
    );

    final headers = {
      'Authorization': _formatAuthHeader(apiKey),
      'Content-Type': 'application/json',
    };

    try {
      debugPrint(
        'TorboxService: requestWebDownloadFileLink webId=$webId fileId=$fileId zipLink=$zipLink',
      );
      final response = await _readWithRetry(uri, headers, policy: retryPolicy);
      debugPrint(
        'TorboxService: requestWebDownloadFileLink status=${response.statusCode}',
      );

      if (response.statusCode >= 300 && response.statusCode < 400) {
        final location = response.headers['location'];
        if (location != null && _isSafeDownloadUrl(location)) {
          return location;
        }
        throw const TorboxRequestException(
          TorboxRequestFailureKind.invalidResponse,
        );
      }

      Map<String, dynamic> payload;
      try {
        final decoded = await decodeJsonAsync(response.body);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Not an object');
        }
        payload = decoded;
      } catch (_) {
        if (response.statusCode == 404) {
          throw const TorboxRequestException(
            TorboxRequestFailureKind.notFound,
            statusCode: 404,
          );
        }
        throw const TorboxRequestException(
          TorboxRequestFailureKind.invalidResponse,
        );
      }
      if (isAuthorizationFailure(response.statusCode, payload)) {
        throw TorboxAuthorizationException(statusCode: response.statusCode);
      }
      if (response.statusCode == 404) {
        throw const TorboxRequestException(
          TorboxRequestFailureKind.notFound,
          statusCode: 404,
        );
      }
      if (response.statusCode != 200) {
        throw TorboxRequestException(
          TorboxRequestFailureKind.apiError,
          statusCode: response.statusCode,
        );
      }
      final bool success = payload['success'] as bool? ?? false;
      if (!success) {
        throw const TorboxRequestException(TorboxRequestFailureKind.apiError);
      }

      final dynamic data = payload['data'];
      if (data is String && _isSafeDownloadUrl(data)) {
        return data;
      }

      throw const TorboxRequestException(
        TorboxRequestFailureKind.invalidResponse,
      );
    } catch (e) {
      debugPrint(
        'TorboxService: requestWebDownloadFileLink failed '
        '(${e.runtimeType})',
      );
      if (e is TorboxAuthorizationException ||
          e is TorboxConnectionException ||
          e is TorboxRequestException) {
        rethrow;
      }
      throw const TorboxRequestException(
        TorboxRequestFailureKind.invalidResponse,
      );
    }
  }

  /// Request ZIP download link for entire web download
  static String createWebDownloadZipPermalink(String apiKey, int webId) {
    final token = _rawApiToken(apiKey);
    final uri = Uri.parse('$_baseUrl/webdl/requestdl').replace(
      queryParameters: {
        'token': token,
        'web_id': '$webId',
        'zip_link': 'true',
        'redirect': 'true',
      },
    );
    return uri.toString();
  }

  /// Create a web download from a URL
  static Future<Map<String, dynamic>> createWebDownload({
    required String apiKey,
    required String link,
    String? name,
    String? password,
    bool asQueued = false,
    bool addOnlyIfCached = false,
  }) async {
    final uri = Uri.parse('$_baseUrl/webdl/createwebdownload');
    final headers = {'Authorization': _formatAuthHeader(apiKey)};

    final request = http.MultipartRequest('POST', uri)
      ..headers.addAll(headers)
      ..fields['link'] = link
      ..fields['as_queued'] = asQueued ? 'true' : 'false'
      ..fields['add_only_if_cached'] = addOnlyIfCached ? 'true' : 'false';

    if (name != null && name.isNotEmpty) {
      request.fields['name'] = name;
    }
    if (password != null && password.isNotEmpty) {
      request.fields['password'] = password;
    }

    try {
      debugPrint('TorboxService: createWebDownload input=<redacted>');
      final response = await request.send().timeout(
        const Duration(seconds: 60), // Longer timeout as per user's request
      );
      final body = await response.stream.bytesToString();
      debugPrint(
        'TorboxService: createWebDownload status=${response.statusCode}',
      );

      final Map<String, dynamic> payload =
          await decodeJsonAsync(body) as Map<String, dynamic>;

      if (response.statusCode == 400) {
        return payload;
      }

      if (response.statusCode != 200) {
        if (response.statusCode == 401) {
          throw Exception('Invalid Torbox API key');
        } else if (response.statusCode == 403) {
          throw Exception('Access denied by Torbox');
        } else if (response.statusCode == 429) {
          throw Exception(
            'Too many requests to Torbox. Please wait and try again',
          );
        } else if (response.statusCode >= 500) {
          throw Exception('Torbox service is temporarily unavailable');
        }
        throw Exception('Failed to add web download to Torbox');
      }

      return payload;
    } catch (e) {
      debugPrint('TorboxService: createWebDownload failed: $e');
      rethrow;
    }
  }

  /// Delete a web download
  static Future<void> deleteWebDownload({
    required String apiKey,
    required int webId,
  }) async {
    final uri = Uri.parse('$_baseUrl/webdl/controlwebdownload');
    final headers = {
      'Authorization': _formatAuthHeader(apiKey),
      'Content-Type': 'application/json',
    };

    final body = json.encode({'webdl_id': webId, 'operation': 'delete'});

    try {
      debugPrint('TorboxService: deleteWebDownload webId=$webId');
      final response = await http
          .post(uri, headers: headers, body: body)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        debugPrint(
          'TorboxService: deleteWebDownload status ${response.statusCode}',
        );
        throw Exception(
          'Failed to delete web download: ${response.statusCode}',
        );
      }

      final Map<String, dynamic> payload =
          await decodeJsonAsync(response.body) as Map<String, dynamic>;
      final bool success = payload['success'] as bool? ?? false;
      if (!success) {
        final dynamic error = payload['error'];
        throw Exception(error?.toString() ?? 'Failed to delete web download');
      }

      debugPrint('TorboxService: Web download $webId deleted successfully');
    } catch (e) {
      debugPrint('TorboxService: deleteWebDownload failed: $e');
      rethrow;
    }
  }

  static String _rawApiToken(String apiKey) {
    final trimmed = apiKey.trim();
    return trimmed.toLowerCase().startsWith('bearer ')
        ? trimmed.substring(7).trim()
        : trimmed;
  }

  static String _formatAuthHeader(String apiKey) {
    return 'Bearer ${_rawApiToken(apiKey)}';
  }
}
