import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// A delete may have reached TorBox even when its response was lost. Never
/// replay destructive POSTs automatically; ask the user to refresh first.
class TorboxDeleteException implements Exception {
  const TorboxDeleteException(this.message);

  final String message;

  @override
  String toString() => message;
}

class TorboxTorrentControlService {
  static const String _endpoint =
      'https://api.torbox.app/v1/api/torrents/controltorrent';

  /// Deterministic request seam; production always uses http.post.
  @visibleForTesting
  static Future<http.Response> Function(
    Uri url,
    Map<String, String> headers,
    String body,
  )?
  debugDeleteTransport;

  static Future<void> deleteTorrent({
    required String apiKey,
    int? torrentId,
    bool deleteAll = false,
  }) async {
    final payload = <String, dynamic>{'operation': 'delete', 'all': deleteAll};
    if (torrentId != null) {
      payload['torrent_id'] = '$torrentId';
    }
    final headers = {
      'Content-Type': 'application/json',
      'Authorization': _formatAuthHeader(apiKey),
    };
    try {
      debugPrint(
        'TorboxTorrentControl: Deleting torrent $torrentId (all=$deleteAll)',
      );
      final url = Uri.parse(_endpoint);
      final encoded = jsonEncode(payload);
      final transport = debugDeleteTransport;
      final response =
          await (transport == null
                  ? http.post(url, headers: headers, body: encoded)
                  : transport(url, headers, encoded))
              .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        debugPrint(
          'TorboxTorrentControl: Delete failed (HTTP ${response.statusCode})',
        );
        if (response.statusCode == 401 || response.statusCode == 403) {
          throw const TorboxDeleteException(
            'Torbox rejected this action. Check the API key and account permissions in Settings.',
          );
        }
        if (response.statusCode == 429) {
          throw const TorboxDeleteException(
            'Torbox is rate-limiting requests. Refresh the list before retrying deletion.',
          );
        }
        if (response.statusCode >= 500) {
          throw TorboxDeleteException(
            'Torbox server error (HTTP ${response.statusCode}). Refresh the list to check whether deletion succeeded before retrying.',
          );
        }
        throw TorboxDeleteException(
          'Torbox could not confirm deletion (HTTP ${response.statusCode}). Refresh the list before retrying.',
        );
      }

      final Map<String, dynamic> body;
      try {
        body = json.decode(response.body) as Map<String, dynamic>;
      } catch (_) {
        throw const TorboxDeleteException(
          'Torbox returned an invalid delete response. Refresh the list before retrying.',
        );
      }
      final bool success = body['success'] as bool? ?? false;
      if (!success) {
        throw const TorboxDeleteException(
          'Torbox did not confirm deletion. Refresh the list before retrying.',
        );
      }
    } on TorboxDeleteException {
      rethrow;
    } on TimeoutException {
      debugPrint('TorboxTorrentControl: Delete timed out (result unknown)');
      throw const TorboxDeleteException(
        'Torbox did not respond to deletion. Refresh the list to see whether it succeeded before retrying.',
      );
    } catch (e) {
      // http errors can contain the request URI, including a private token.
      debugPrint(
        'TorboxTorrentControl: Delete transport failed (${e.runtimeType})',
      );
      throw const TorboxDeleteException(
        'Unable to confirm Torbox deletion. Check the connection and refresh the list before retrying.',
      );
    }
  }

  static String _formatAuthHeader(String apiKey) {
    final trimmed = apiKey.trim();
    if (trimmed.toLowerCase().startsWith('bearer ')) {
      return trimmed;
    }
    return 'Bearer $trimmed';
  }
}
