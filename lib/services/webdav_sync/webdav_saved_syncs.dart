import 'dart:convert';

import 'package:synchronized/synchronized.dart';

import '../profiles/device_key_provider.dart';
import '../profiles/profile_preferences.dart';
import 'webdav_sync_connect_controller.dart';

/// Saved logins belong to this device, independently of the active sync state.
/// The entire list is sealed so usernames and endpoints remain private too.
final class WebDavSavedSync {
  const WebDavSavedSync({required this.name, required this.credentials});

  final String name;
  final WebDavSyncLoginCredentials credentials;

  String get id =>
      '${credentials.endpoint.toString().replaceFirst(RegExp(r'/+$'), '')}\n${credentials.username}';
}

final class WebDavSavedSyncs {
  static const storageKey = 'webdav_saved_syncs_v1';
  static final _lock = Lock();

  Future<List<WebDavSavedSync>> load() async {
    final sealed = (await DevicePreferences.instance()).getString(storageKey);
    if (sealed == null) return [];
    final clear = await DeviceKeyProvider.cipher.open(
      sealed,
      associatedData: utf8.encode(storageKey),
    );
    final rows = jsonDecode(utf8.decode(clear)) as List;
    return rows
        .map(
          (row) => WebDavSavedSync(
            name: row['name'] as String,
            credentials: WebDavSyncLoginCredentials(
              endpoint: Uri.parse(row['endpoint'] as String),
              username: row['username'] as String,
              password: row['password'] as String,
              serverName: row['serverName'] as String,
            ),
          ),
        )
        .toList();
  }

  Future<void> importCurrentIfNeeded(WebDavSavedSync sync) =>
      _lock.synchronized(() async {
        if ((await DevicePreferences.instance()).getString(storageKey) !=
            null) {
          return;
        }
        await _write([sync]);
      });

  Future<void> save(WebDavSavedSync sync) => _lock.synchronized(() async {
    final rows = await load();
    final index = rows.indexWhere((row) => row.id == sync.id);
    if (index < 0) {
      rows.add(sync);
    } else {
      rows[index] = sync;
    }
    await _write(rows);
  });

  Future<void> remove(String id) => _lock.synchronized(() async {
    final rows = await load();
    rows.removeWhere((row) => row.id == id);
    await _write(rows);
  });

  Future<void> _write(List<WebDavSavedSync> rows) async {
    final bytes = utf8.encode(
      jsonEncode(
        rows
            .map(
              (row) => {
                'name': row.name,
                'endpoint': row.credentials.endpoint.toString(),
                'username': row.credentials.username,
                'password': row.credentials.password,
                'serverName': row.credentials.serverName,
              },
            )
            .toList(),
      ),
    );
    if (bytes.length > 32 * 1024) {
      throw StateError('Saved syncs are full. Remove a saved sync first.');
    }
    final sealed = await DeviceKeyProvider.cipher.seal(
      bytes,
      associatedData: utf8.encode(storageKey),
    );
    if (!await (await DevicePreferences.instance()).setBudgetedString(
      storageKey,
      sealed,
    )) {
      throw StateError('Could not save sync connections');
    }
  }
}
