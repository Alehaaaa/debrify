import 'dart:convert';
import 'dart:typed_data';

import 'package:debrify/services/profiles/portable_profile_package.dart';
import 'package:debrify/services/profiles/profile_app_assets_codec.dart';
import 'package:debrify/services/profiles/profile_preference_portability.dart';
import 'package:flutter_test/flutter_test.dart';

/// String cap that builds before app assets apply outside package sections.
const int _legacyMaxStringBytes = 4 * 1024 * 1024;

void main() {
  const fontPath = 'assets/subtitle-fonts/custom_1720000000000';
  const launchPath =
      'assets/launch-animations/0123456789abcdef0123456789abcdef';

  Uint8List bytesOf(int length) =>
      Uint8List.fromList(List<int>.generate(length, (index) => index % 251));

  test('large assets round-trip in chunks older builds accept', () async {
    final bytes = bytesOf(ProfileAppAssetsCodec.maxLaunchAnimationBytes);
    final record = await ProfileAppAssetsCodec.encode(bytes);
    final chunks = record['chunks']! as List<String>;
    expect(chunks.length, greaterThan(1));
    for (final chunk in chunks) {
      expect(utf8.encode(chunk).length, lessThan(_legacyMaxStringBytes));
    }
    expect(await ProfileAppAssetsCodec.decode(launchPath, record), bytes);
  });

  test('tampered, oversized and unknown assets are rejected', () async {
    final record = await ProfileAppAssetsCodec.encode(bytesOf(64));
    final tampered = <String, Object?>{
      ...record,
      'chunks': <String>[base64Encode(bytesOf(63) + [7])],
    };
    await expectLater(
      ProfileAppAssetsCodec.decode(fontPath, tampered),
      throwsFormatException,
    );
    await expectLater(
      ProfileAppAssetsCodec.decode('engines/example.json', record),
      throwsFormatException,
    );
    await expectLater(
      ProfileAppAssetsCodec.decode('assets/subtitle-fonts/../x', record),
      throwsFormatException,
    );
    final oversized = await ProfileAppAssetsCodec.encode(
      bytesOf(ProfileAppAssetsCodec.maxFontBytes + 1),
    );
    await expectLater(
      ProfileAppAssetsCodec.decode(fontPath, oversized),
      throwsFormatException,
    );
  });

  Future<PortableProfilePackage> packageWith(Object? appAssets) async =>
      PortableProfilePackage(
        mode: 'singleProfile',
        createdAt: DateTime.utc(2026, 10, 2),
        profiles: <Map<String, dynamic>>[
          <String, dynamic>{
            'backupId': 'profile-0',
            'name': 'Profile',
            'preferencesSection': 'preferences',
            ProfileAppAssetsCodec.field: appAssets,
          },
        ],
        resources: const <Map<String, dynamic>>[],
        sections: <String, dynamic>{
          'preferences': await PortableProfilePackage.buildSection(
            const <String, Object?>{'app_theme': 'spotlight'},
          ),
        },
        omissions: const <String, dynamic>{},
      );

  test(
    'app assets ride on the profile record within legacy limits',
    () async {
      final assets = <String, Object?>{
        fontPath: await ProfileAppAssetsCodec.encode(
          bytesOf(2048),
          metadata: const <String, Object?>{
            'label': 'Mine',
            'fontFamily': 'Mine',
            'fileName': 'Mine (Bold).ttf',
            'selected': true,
          },
        ),
        launchPath: await ProfileAppAssetsCodec.encode(
          bytesOf(ProfileAppAssetsCodec.maxLaunchAnimationBytes),
        ),
        ProfileAppAssetsCodec.appSettingsPath: await ProfileAppAssetsCodec
            .encode(utf8.encode(jsonEncode({'remote_intro_shown': true}))),
      };
      final encoded = jsonEncode(
        await PortableProfilePackage.withIntegrity(await packageWith(assets)),
      );

      // What a previous build checks: no new sections, no non-engine
      // filesSection keys, and no string outside sections above 4 MiB.
      final decodedJson = jsonDecode(encoded) as Map<String, dynamic>;
      expect((decodedJson['sections'] as Map).keys, <String>['preferences']);
      void walk(Object? value, String path) {
        if (value is String && !path.contains('.sections.')) {
          expect(
            utf8.encode(value).length,
            lessThanOrEqualTo(_legacyMaxStringBytes),
            reason: path,
          );
        } else if (value is Map) {
          for (final entry in value.entries) {
            walk(entry.value, '$path.${entry.key}');
          }
        } else if (value is List) {
          for (var index = 0; index < value.length; index++) {
            walk(value[index], '$path[$index]');
          }
        }
      }

      walk(decodedJson, r'$');
      expect(
        ProfilePreferencePortability.allowsKey('imported_launch_animation_v1'),
        isFalse,
      );
      expect(
        ProfilePreferencePortability.prepareValue(
          'subtitle_selected_font_id',
          'custom_1720000000000',
        ).include,
        isFalse,
      );

      final restored = await PortableProfilePackage.decodeAuthenticatedJson(
        encoded,
      );
      expect(
        (restored.profiles.single[ProfileAppAssetsCodec.field] as Map).keys,
        unorderedEquals(assets.keys),
      );
    },
  );

  test('current builds reject a forged asset path on the profile', () async {
    final forged = <String, Object?>{
      'assets/../engines/x.json': await ProfileAppAssetsCodec.encode(
        bytesOf(8),
      ),
    };
    final encoded = jsonEncode(
      await PortableProfilePackage.withIntegrity(await packageWith(forged)),
    );
    await expectLater(
      PortableProfilePackage.decodeAuthenticatedJson(encoded),
      throwsFormatException,
    );
  });
}
