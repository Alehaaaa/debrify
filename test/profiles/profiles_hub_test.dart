import 'dart:io';

import 'package:debrify/models/profiles/profile_policy.dart';
import 'package:debrify/models/profiles/user_profile.dart';
import 'package:debrify/screens/settings/profiles_settings_page.dart';
import 'package:debrify/services/profiles/profile_bootstrap.dart';
import 'package:debrify/services/profiles/profile_lock_controller.dart';
import 'package:debrify/services/profiles/profile_registry.dart';
import 'package:debrify/services/profiles/profile_runtime.dart';
import 'package:debrify/services/profiles/profile_scope.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/theme/glass_chrome.dart';
import 'package:debrify/theme/premium_looks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// The hub's contract: the active identity is distinct from the other-profile
/// roster, with device behavior and household actions grouped separately.
void main() {
  late Directory temporaryDirectory;
  late ProfileRegistry registry;
  late String adminId;
  late String memberId;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    temporaryDirectory = await Directory.systemTemp.createTemp('hub-test-');
    registry = await ProfileRegistry.open(
      path: p.join(temporaryDirectory.path, 'profiles.db'),
    );
    adminId = (await registry.createProfile(
      name: 'Boss',
      role: UserProfileRole.admin,
    )).id;
    memberId = (await registry.createProfile(
      name: 'Maya',
      role: UserProfileRole.child,
    )).id;
    await registry.commitBootstrap(
      activeProfileId: adminId,
      migratedLegacyInstall: false,
    );
    ProfileBootstrap.debugInstallRegistry(registry);
    ProfileRuntime.debugReset();
    ProfileRuntime.initializeCommitted(
      ProfileScope(profileId: adminId, dataGeneration: 1, sessionEpoch: 1),
    );
  });

  tearDown(() async {
    ProfileLockController.instance.dispose();
    ProfileRuntime.debugReset();
    ProfileBootstrap.debugInstallRegistry(null);
    await registry.close();
    await temporaryDirectory.delete(recursive: true);
  });

  // Real registry IO completes only inside runAsync windows, and avatar art
  // animates continuously (pumpAndSettle would never settle) — so interleave
  // bounded real-async waits with pumps, the house pattern for these
  // screens.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> pumpHub(
    WidgetTester tester, {
    Size size = const Size(900, 1400),
    AppTheme? appearance,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final app = const MaterialApp(home: ProfilesSettingsPage());
    await tester.pumpWidget(
      appearance == null ? app : AppThemeScope(theme: appearance, child: app),
    );
    await settle(tester);
  }

  testWidgets('profile actions reopen with the active Settings appearance', (
    tester,
  ) async {
    final classic = PremiumLooks.field.build();
    await pumpHub(tester, appearance: classic);
    await tester.tap(find.text('Maya'));
    await settle(tester);
    var dialogContext = tester.element(find.byType(SimpleDialog));
    expect(
      Theme.of(dialogContext).dialogTheme.backgroundColor,
      classic.settings.panel2,
    );
    await tester.binding.handlePopRoute();
    await settle(tester);

    final frosted = PremiumLooks.glass.build();
    await pumpHub(tester, appearance: frosted);
    await tester.tap(find.text('Maya'));
    await settle(tester);
    dialogContext = tester.element(find.byType(SimpleDialog));
    final theme = Theme.of(dialogContext).dialogTheme;
    expect(theme.backgroundColor, GlassChrome.fill(frosted, raised: true));
    expect(
      (theme.shape! as RoundedRectangleBorder).side.color,
      GlassChrome.edge(frosted),
    );
  });

  testWidgets('level one separates the active identity and other profiles', (
    tester,
  ) async {
    await pumpHub(tester);

    expect(find.text('CURRENT PROFILE'), findsOneWidget);
    expect(find.text('Admin · Signed in'), findsOneWidget);
    expect(find.text('OTHER PROFILES'), findsOneWidget);
    expect(find.text('Kid'), findsOneWidget);

    // Only profile-specific actions remain in this hub. Backup/restore belongs
    // to Data & Backup and picker presentation belongs to Appearance.
    expect(find.text('Switch profile'), findsOneWidget);
    expect(find.text('Edit profile'), findsOneWidget);
    expect(find.text('Create a profile'), findsOneWidget);
    expect(find.text('Send profiles to TV'), findsOneWidget);
    expect(find.text('Back up'), findsNothing);
    expect(find.text('Restore'), findsNothing);
    expect(find.text("Who's-watching style"), findsNothing);
  });

  testWidgets('a profile row opens one action panel that can disable', (
    tester,
  ) async {
    await pumpHub(tester);

    await tester.tap(find.text('Maya'));
    await settle(tester);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Switch to this profile'), findsOneWidget);
    expect(find.text('Disable profile'), findsOneWidget);
    expect(find.text('Delete profile'), findsOneWidget);

    await tester.tap(find.text('Disable profile'));
    await settle(tester);

    // The hub keeps showing the disabled profile (managers must see it to
    // re-enable or delete), badged accordingly.
    expect(find.text('Kid · disabled'), findsOneWidget);
  });

  testWidgets('the active profile is not duplicated in the roster', (
    tester,
  ) async {
    await pumpHub(tester);
    expect(find.text('Boss'), findsOneWidget);
    expect(find.byKey(const ValueKey('profiles-switch')), findsOneWidget);
    expect(find.byKey(const ValueKey('profiles-edit-current')), findsOneWidget);
  });

  testWidgets('compact layout stacks without clipping profile actions', (
    tester,
  ) async {
    await pumpHub(tester, size: const Size(390, 844));

    expect(find.byKey(const ValueKey('profiles-switch')), findsOneWidget);
    expect(find.byKey(const ValueKey('profiles-create')), findsOneWidget);
    expect(find.byKey(const ValueKey('profiles-always-ask')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a non-admin can open only the active-profile self editor', (
    tester,
  ) async {
    late UserProfile member;
    await tester.runAsync(() async {
      await registry.setActiveProfile(memberId);
      member = (await registry.getProfile(memberId))!;
    });
    ProfileRuntime.publish(
      ProfileScope(profileId: memberId, dataGeneration: 1, sessionEpoch: 2),
    );
    ProfileLockController.instance.unlock(member);

    await pumpHub(tester, size: const Size(390, 844));

    expect(find.byKey(const ValueKey('profiles-edit-self')), findsOneWidget);
    expect(find.byKey(const ValueKey('profiles-edit-current')), findsNothing);
    expect(find.byKey(const ValueKey('profiles-create')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('profiles-edit-self')));
    await settle(tester);

    expect(find.text('Edit your profile'), findsOneWidget);
    expect(find.byKey(const ValueKey('self-profile-name')), findsOneWidget);
    expect(find.text('ROLE'), findsNothing);
    expect(find.text('Permissions'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
