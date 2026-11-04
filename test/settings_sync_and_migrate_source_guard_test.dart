import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final adaptive = File('lib/screens/settings_screen.dart').readAsStringSync();
  final tv = File(
    'lib/screens/settings/settings_tv_layout.dart',
  ).readAsStringSync();
  final page = File(
    'lib/screens/settings/sync_and_migrate_page.dart',
  ).readAsStringSync();

  test('adaptive, TV, and search surfaces group sync under Data & Backup', () {
    expect(adaptive, isNot(contains("label: 'Sync and Migrate'")));
    expect(
      adaptive,
      contains("SettingsRows.syncAndMigrate,\n        'Data & Backup'"),
    );
    expect(adaptive, contains("title: 'Data & Backup'"));
    expect(
      tv,
      contains("'Data & Backup',\n    'Sync, downloads, backup & restore'"),
    );
    expect(page, isNot(contains('SettingsRows.createWebDavBackup')));
    expect(page, isNot(contains('SettingsRows.restoreWebDavBackup')));
  });

  test('Discover defaults live with Appearance screen layouts', () {
    expect(adaptive, isNot(contains("label: 'Discover'")));
    expect(
      adaptive,
      matches(
        RegExp(r"title: 'Screen layouts'[\s\S]*?SettingsRows\.discoverDefault"),
      ),
    );
    expect(tv, isNot(contains("case 9: // Discover")));
    expect(
      tv,
      matches(
        RegExp(r"title: 'Screen layouts'[\s\S]*?SettingsRows\.discoverDefault"),
      ),
    );
  });

  test('index-based category switches preserve the destructive tail', () {
    expect(
      adaptive,
      matches(
        RegExp(
          r'case 8:[\s\S]*?SettingsRows\.syncAndMigrate[\s\S]*?SettingsRows\.downloadLocation[\s\S]*?case 9:[\s\S]*?SettingsRows\.autoUpdate[\s\S]*?case 10:[\s\S]*?SettingsRows\.resetDebrify',
        ),
      ),
    );
    expect(
      tv,
      matches(
        RegExp(
          r'case 8: // Data & Backup[\s\S]*?case 9: // About[\s\S]*?case 10: // Danger Zone',
        ),
      ),
    );
  });
}
