import 'package:debrify/services/profiles/device_key_provider.dart';
import 'package:debrify/services/webdav_sync/webdav_saved_syncs.dart';
import 'package:debrify/services/webdav_sync/webdav_sync_connect_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

WebDavSavedSync entry(
  String username, {
  String name = 'My sync',
  String password = 'private-password',
  bool trailingSlash = false,
}) => WebDavSavedSync(
  name: name,
  credentials: WebDavSyncLoginCredentials(
    endpoint: Uri.parse('https://example.com/dav${trailingSlash ? '/' : ''}'),
    username: username,
    password: password,
    serverName: 'WebDAV',
  ),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DeviceKeyProvider.debugInstallCipher(
      MemoryDeviceSecretCipher(List.generate(32, (i) => i)),
    );
  });
  tearDown(DeviceKeyProvider.debugReset);

  test('saved logins survive store recreation and remain encrypted', () async {
    await WebDavSavedSyncs().save(entry('alice'));
    final raw = (await SharedPreferences.getInstance()).getString(
      WebDavSavedSyncs.storageKey,
    )!;
    expect(raw, isNot(contains('private-password')));
    expect(raw, isNot(contains('alice')));
    final saved = await WebDavSavedSyncs().load();
    expect(saved.single.credentials.password, 'private-password');
    expect(saved.single.name, 'My sync');
  });

  test(
    'accounts on one provider remain distinct; updates deduplicate',
    () async {
      final store = WebDavSavedSyncs();
      await store.save(entry('alice'));
      await store.save(entry('bob'));
      await store.save(
        entry('alice', name: 'Home', password: 'updated', trailingSlash: true),
      );
      final saved = await store.load();
      expect(saved, hasLength(2));
      expect(saved.first.name, 'Home');
      expect(saved.first.credentials.password, 'updated');
      await store.remove(saved.first.id);
      expect((await store.load()).single.credentials.username, 'bob');
    },
  );

  test('concurrent saves preserve every account', () async {
    await Future.wait(
      List.generate(5, (i) => WebDavSavedSyncs().save(entry('user-$i'))),
    );
    expect(await WebDavSavedSyncs().load(), hasLength(5));
  });

  test('wrong vault key cannot read or overwrite saved logins', () async {
    final store = WebDavSavedSyncs();
    await store.save(entry('alice'));
    final prefs = await SharedPreferences.getInstance();
    final before = prefs.getString(WebDavSavedSyncs.storageKey);
    DeviceKeyProvider.debugInstallCipher(
      MemoryDeviceSecretCipher(List.generate(32, (i) => i + 1)),
    );
    await expectLater(store.load(), throwsA(anything));
    await expectLater(store.save(entry('bob')), throwsA(anything));
    expect(prefs.getString(WebDavSavedSyncs.storageKey), before);
  });
}
