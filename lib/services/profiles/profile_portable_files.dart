import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../../models/profiles/profile_avatar.dart';
import '../../utils/app_storage.dart';
import '../launch_animation/launch_animation_library.dart';
import '../subtitle_font_service.dart';
import 'profile_app_assets_codec.dart';
import 'profile_avatar_ingest.dart';
import 'profile_avatar_policy.dart';
import 'profile_avatar_storage.dart';
import 'profile_preferences.dart';
import 'profile_scope.dart';
import 'profile_storage_paths.dart';

/// Allowlisted portable files. Device assets, caches, executable paths, OS
/// grants, downloads, and recordings deliberately never enter this codec.
class ProfilePortableFiles {
  ProfilePortableFiles._();

  static const int maxFileBytes = 4 * 1024 * 1024;
  static const int maxTotalBytes = 64 * 1024 * 1024;

  /// Exports only the legacy-compatible engine tree.
  ///
  /// Avatar bytes deliberately live in the profile record's optional
  /// `avatarFile` attachment (see [exportAvatar]). Previous builds validate
  /// every `filesSection` key against the `engines/` grammar and abort the
  /// whole import on an avatar path; they safely ignore an unknown profile
  /// field, so separating the attachment is the compatibility boundary.
  static Future<Map<String, Object?>> export(ProfileScope scope) async {
    final root = await ProfileStoragePaths.profileDataRoot();
    final documents = scope.storageDirectory(root, 'documents');
    final engines = Directory(p.join(documents.path, 'engines'));
    if (!await engines.exists()) return const <String, Object?>{};
    final result = <String, Object?>{};
    var total = 0;
    await for (final entity in engines.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Link) throw StateError('Portable files contain a symlink');
      if (entity is! File) continue;
      final relative = p
          .relative(entity.path, from: documents.path)
          .replaceAll(r'\', '/');
      if (!_allowedEngine(relative)) continue;
      final length = await entity.length();
      total += length;
      if (length > maxFileBytes || total > maxTotalBytes) {
        throw StateError('Portable profile files exceed the backup limit');
      }
      final bytes = await entity.readAsBytes();
      result[relative] = await _attachment(bytes);
    }
    return result;
  }

  /// App-level settings that follow the user across devices. Hardware
  /// tuning, credentials, local paths, jobs and device identity stay local.
  static const Set<String> syncedAppSettingKeys = <String>{
    'remote_intro_shown',
    'update_auto_check_enabled',
    'update_include_alpha_enabled',
    'profile_gate_style_v1',
    'profile_gate_always_ask_v1',
  };

  /// Exports the device assets for the profile-record
  /// [ProfileAppAssetsCodec.field]: every imported subtitle font (stable IDs),
  /// the profile's selected imported launch animation, and the synced app
  /// settings. The two profile selections are read by the caller's reviewed
  /// preference access and passed in. Optional assets that are missing,
  /// unreadable or over the limit are omitted rather than failing the backup
  /// or sync around them.
  static Future<Map<String, Object?>> exportAppAssets({
    String? selectedLaunchAnimationId,
    String? selectedSubtitleFontId,
  }) async {
    final DevicePreferences device;
    try {
      device = await DevicePreferences.instance();
    } catch (_) {
      // Pure Dart codec tests run without Flutter's services binding.
      return const <String, Object?>{};
    }
    final result = <String, Object?>{};
    var total = 0;

    Future<List<int>?> readBounded(File file, int maxBytes) async {
      try {
        final length = await file.length();
        if (length > maxBytes ||
            total + length > ProfileAppAssetsCodec.maxTotalBytes) {
          return null;
        }
        final bytes = await file.readAsBytes();
        total += bytes.length;
        return bytes;
      } on FileSystemException {
        return null;
      }
    }

    // The selected face first, so the total budget never drops the one font
    // this profile actually uses in favour of unused ones.
    final fonts = _customFontRegistry(device)
      ..sort(
        (left, right) => (left.id == selectedSubtitleFontId ? 0 : 1).compareTo(
          right.id == selectedSubtitleFontId ? 0 : 1,
        ),
      );
    for (final font in fonts) {
      final path = font.path;
      final family = font.fontFamily;
      final assetPath = '${ProfileAppAssetsCodec.fontPrefix}${font.id}';
      if (path == null ||
          family == null ||
          !ProfileAppAssetsCodec.isAllowedPath(assetPath)) {
        continue;
      }
      final bytes = await readBounded(
        File(path),
        ProfileAppAssetsCodec.maxFontBytes,
      );
      if (bytes == null) continue;
      result[assetPath] = await ProfileAppAssetsCodec.encode(
        bytes,
        metadata: <String, Object?>{
          'label': font.label,
          'fontFamily': family,
          'fileName': p.basename(path),
          if (font.id == selectedSubtitleFontId) 'selected': true,
        },
      );
    }

    final launchPath =
        '${ProfileAppAssetsCodec.launchPrefix}$selectedLaunchAnimationId';
    if (selectedLaunchAnimationId != null &&
        ProfileAppAssetsCodec.isAllowedPath(launchPath)) {
      try {
        final library = LaunchAnimationLibrary.instance;
        final installed = (await library.list())
            .where((entry) => entry.id == selectedLaunchAnimationId)
            .firstOrNull;
        if (installed != null) {
          final bytes = await readBounded(
            await library.originalFile(selectedLaunchAnimationId),
            ProfileAppAssetsCodec.maxLaunchAnimationBytes,
          );
          if (bytes != null) {
            result[launchPath] = await ProfileAppAssetsCodec.encode(
              bytes,
              metadata: <String, Object?>{
                'animationId': installed.animationId,
                'background': installed.background,
              },
            );
          }
        }
      } on Exception catch (error) {
        debugPrint('Omitted launch animation from portable assets: $error');
      }
    }

    final appSettings = <String, Object?>{
      for (final key in syncedAppSettingKeys)
        if (device.get(key) case final Object value) key: value,
    };
    if (appSettings.isNotEmpty) {
      result[ProfileAppAssetsCodec.appSettingsPath] =
          await ProfileAppAssetsCodec.encode(
            utf8.encode(jsonEncode(appSettings)),
          );
    }
    return result;
  }

  /// Installs authenticated app assets and reports which selections they
  /// carried. A selection is reported only when its asset is usable here;
  /// otherwise the app falls back to its built-in animation or font.
  ///
  /// Fonts and animations are additive device assets; an asset this build
  /// cannot use is skipped instead of failing the profile restore.
  static Future<ProfileAppAssetsRestore> restoreAppAssets(
    Object? field, {
    bool applyAppSettings = true,
  }) async {
    if (field == null) return const ProfileAppAssetsRestore();
    await ProfileAppAssetsCodec.validate(field);
    final assets = Map<String, Object?>.from(field as Map);
    String? launchId;
    String? fontId;
    for (final entry in assets.entries) {
      final path = entry.key;
      final record = entry.value as Map;
      final bytes = await ProfileAppAssetsCodec.decode(path, record);
      if (path.startsWith(ProfileAppAssetsCodec.fontPrefix)) {
        try {
          final font = await SubtitleFontService.instance.restoreCustomFont(
            id: path.substring(ProfileAppAssetsCodec.fontPrefix.length),
            label: record['label'] as String? ?? '',
            fontFamily: record['fontFamily'] as String? ?? '',
            fileName: record['fileName'] as String? ?? 'font.ttf',
            bytes: bytes,
          );
          if (font == null) {
            debugPrint('Skipped an unusable synced font');
          } else if (record['selected'] == true) {
            fontId = font.id;
          }
        } on Exception catch (error) {
          debugPrint('Skipped a synced font: $error');
        }
      } else if (path.startsWith(ProfileAppAssetsCodec.launchPrefix)) {
        final id = path.substring(ProfileAppAssetsCodec.launchPrefix.length);
        launchId = await _installLaunchAnimation(id, record, bytes) ?? launchId;
      } else if (path == ProfileAppAssetsCodec.appSettingsPath &&
          applyAppSettings) {
        await _applyAppSettings(bytes);
      }
    }
    return ProfileAppAssetsRestore(
      launchAnimationId: launchId,
      subtitleFontId: fontId,
    );
  }

  static Future<String?> _installLaunchAnimation(
    String id,
    Map record,
    List<int> bytes,
  ) async {
    final library = LaunchAnimationLibrary.instance;
    final root = await ProfileStoragePaths.profileDataRoot();
    final temporary = File(p.join(root.path, '.launch-restore-$id.lottie'));
    try {
      if ((await library.list()).any((entry) => entry.id == id)) return id;
      await temporary.writeAsBytes(bytes, flush: true);
      final animationId = record['animationId'];
      final background = record['background'];
      await library.install(
        temporary,
        animationId: animationId is String ? animationId : null,
        background: background is int ? background : null,
        preferredLibraryId: id,
      );
      return id;
    } on Exception catch (error) {
      debugPrint('Skipped a synced launch animation: $error');
      return null;
    } finally {
      try {
        if (await temporary.exists()) await temporary.delete();
      } on FileSystemException {
        // Best-effort cleanup of a scratch file.
      }
    }
  }

  static Future<void> _applyAppSettings(List<int> bytes) async {
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const FormatException('Synced app settings are invalid');
    }
    if (decoded is! Map) {
      throw const FormatException('Synced app settings are invalid');
    }
    final device = await DevicePreferences.instance();
    for (final key in syncedAppSettingKeys) {
      if (!decoded.containsKey(key)) continue;
      final value = decoded[key];
      // A type this build does not expect is ignored, not fatal: a newer
      // build may legitimately evolve a setting's representation.
      final saved = switch (value) {
        final bool value => await device.setBool(key, value),
        final int value => await device.setInt(key, value),
        final String value => await device.setString(key, value),
        final List value when value.every((item) => item is String) =>
          await device.setStringList(key, List<String>.from(value)),
        _ => true,
      };
      if (!saved) {
        throw StateError('Synced app setting $key could not be saved');
      }
    }
  }

  static List<SubtitleFont> _customFontRegistry(DevicePreferences device) {
    final json = device.getString('subtitle_custom_fonts');
    if (json == null) return <SubtitleFont>[];
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return <SubtitleFont>[];
      return decoded
          .whereType<Map>()
          .map(
            (value) => SubtitleFont.fromJson(Map<String, dynamic>.from(value)),
          )
          .toList();
    } on Object {
      // A damaged local registry must not prevent the rest of a backup.
      return <SubtitleFont>[];
    }
  }

  /// Exports exactly the file referenced by [avatarKey], never a directory
  /// sweep. Stale photos therefore neither leak into backups nor consume the
  /// package budget.
  static Future<Map<String, Object?>?> exportAvatar(
    ProfileScope scope,
    String? avatarKey,
  ) async {
    if (!ProfileAvatarPolicy.userImagesSupported) return null;
    final avatar = ProfileAvatar.tryParse(avatarKey);
    if (avatar?.kind != ProfileAvatarKind.image) return null;
    final file = await ProfileAvatarStorage.resolveExisting(
      scope.profileId,
      avatar,
    );
    if (file == null) return null;
    final length = await file.length();
    if (length > ProfileAvatarIngest.maxBytes) {
      throw StateError('Portable avatar exceeds the backup limit');
    }
    final bytes = await file.readAsBytes();
    await ProfileAvatarIngest.validateStored(
      relativePath: avatar!.id,
      bytes: bytes,
    );
    return <String, Object?>{'path': avatar.id, ...await _attachment(bytes)};
  }

  static Future<int> restore(
    ProfileScope scope,
    Map<Object?, Object?> attachments,
  ) async {
    final root = await ProfileStoragePaths.profileDataRoot();
    var total = 0;
    var restored = 0;
    for (final entry in attachments.entries) {
      final relative = entry.key;
      final record = entry.value;
      if (relative is! String || !_allowedEngine(relative) || record is! Map) {
        throw const FormatException('Invalid portable profile file');
      }
      final bytes = await _decodeAttachment(record, maxBytes: maxFileBytes);
      total += bytes.length;
      if (total > maxTotalBytes) {
        throw const FormatException('Portable profile file size mismatch');
      }
      final destination = scope.fileIn(
        root,
        'documents',
        p.joinAll(relative.split('/')),
      );
      await destination.parent.create(recursive: true);
      final temp = File('${destination.path}.restore.tmp');
      if (await temp.exists()) await temp.delete();
      try {
        await temp.writeAsBytes(bytes, flush: true);
        if (await destination.exists()) await destination.delete();
        await temp.rename(destination.path);
        restored++;
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    }
    return restored;
  }

  /// Validates an optional profile-record avatar and writes it only to the
  /// staged generation. [ProfilePortableAvatarStage.install] is the explicit
  /// pre-publication commit; rollback can therefore remove every live write.
  static Future<ProfilePortableAvatarStage?> stageAvatar({
    required ProfileScope scope,
    required Object? record,
    required String? expectedAvatarKey,
    required String operationId,
  }) async {
    if (record == null) return null;
    final expected = ProfileAvatar.tryParse(expectedAvatarKey);
    if (expected?.kind != ProfileAvatarKind.image ||
        record is! Map ||
        record['path'] != expected!.id ||
        !ProfileScope.isValidProfileId(operationId)) {
      throw const FormatException('Invalid portable avatar attachment');
    }
    final bytes = await _decodeAttachment(
      record,
      maxBytes: ProfileAvatarIngest.maxBytes,
    );
    await ProfileAvatarIngest.validateStored(
      relativePath: expected.id,
      bytes: bytes,
    );
    if (!ProfileAvatarPolicy.userImagesSupported) return null;

    final root = await ProfileStoragePaths.profileDataRoot();
    final stagingDirectory = Directory(
      p.join(
        scope.storageDirectory(root, 'documents').path,
        '.avatar-restore',
        operationId,
      ),
    );
    final stagedFile = File(
      p.join(stagingDirectory.path, p.posix.basename(expected.id)),
    );
    await stagedFile.parent.create(recursive: true);
    await stagedFile.writeAsBytes(bytes, flush: true);
    return ProfilePortableAvatarStage._(
      profileId: scope.profileId,
      avatar: expected,
      stagedFile: stagedFile,
      stagingDirectory: stagingDirectory,
    );
  }

  static bool _allowedEngine(String relative) {
    final normalized = p.posix.normalize(relative);
    if (p.posix.isAbsolute(normalized) ||
        RegExp(r'^[A-Za-z]:').hasMatch(normalized) ||
        normalized == '..' ||
        normalized.startsWith('../') ||
        !normalized.startsWith('engines/')) {
      return false;
    }
    final extension = p.posix.extension(normalized).toLowerCase();
    return extension == '.yaml' || extension == '.yml' || extension == '.json';
  }

  static Future<Map<String, Object?>> _attachment(List<int> bytes) async =>
      <String, Object?>{
        'encoding': 'base64',
        'bytes': bytes.length,
        'sha256': await _hash(bytes),
        'data': base64Encode(bytes),
      };

  static Future<Uint8List> _decodeAttachment(
    Map record, {
    required int maxBytes,
  }) async {
    if (record['encoding'] != 'base64' ||
        record['bytes'] is! num ||
        record['sha256'] is! String ||
        record['data'] is! String) {
      throw const FormatException('Invalid portable file attachment');
    }
    final claimed = (record['bytes'] as num).toInt();
    if (claimed < 0 || claimed > maxBytes) {
      throw const FormatException('Portable profile file exceeds limit');
    }
    final encoded = record['data'] as String;
    if (encoded.length > ((maxBytes + 2) ~/ 3) * 4) {
      throw const FormatException('Encoded portable file exceeds limit');
    }
    late final Uint8List bytes;
    try {
      bytes = base64Decode(encoded);
    } on FormatException {
      throw const FormatException('Portable file is not valid base64');
    }
    if (bytes.length != claimed || await _hash(bytes) != record['sha256']) {
      throw const FormatException('Portable profile file digest mismatch');
    }
    return bytes;
  }

  static Future<String> _hash(List<int> bytes) async =>
      base64UrlEncode((await Sha256().hash(bytes)).bytes).replaceAll('=', '');
}

/// One validated avatar staged for a restore operation.
class ProfilePortableAvatarStage {
  final String profileId;
  final ProfileAvatar avatar;
  final File stagedFile;
  final Directory stagingDirectory;
  bool _installedNewFile = false;

  ProfilePortableAvatarStage._({
    required this.profileId,
    required this.avatar,
    required this.stagedFile,
    required this.stagingDirectory,
  });

  /// Materializes the candidate immediately before registry publication. A
  /// pre-existing content-addressed destination is left untouched.
  Future<void> install() async {
    final destination = await ProfileAvatarStorage.fileFor(profileId, avatar);
    if (await destination.exists()) return;
    await destination.parent.create(recursive: true);
    final temp = File('${destination.path}.restore.tmp');
    if (await temp.exists()) await temp.delete();
    try {
      await stagedFile.copy(temp.path);
      final handle = await temp.open(mode: FileMode.append);
      try {
        await handle.flush();
      } finally {
        await handle.close();
      }
      await temp.rename(destination.path);
      _installedNewFile = true;
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }

  /// Removes live bytes created by [install] when publication fails.
  Future<void> rollback() async {
    if (_installedNewFile) {
      final destination = await ProfileAvatarStorage.fileFor(profileId, avatar);
      if (await destination.exists()) await destination.delete();
      _installedNewFile = false;
    }
    await _deleteStaging();
  }

  /// Completes a published restore and prunes every unreferenced old photo.
  Future<void> finish() async {
    await ProfileAvatarIngest.commit(
      profileId: profileId,
      avatarKey: avatar.format(),
    );
    await _deleteStaging();
  }

  Future<void> _deleteStaging() async {
    if (await stagingDirectory.exists()) {
      await stagingDirectory.delete(recursive: true);
    }
  }
}

/// Selections carried by restored app assets. Each ID is set only when its
/// asset is installed on this device.
final class ProfileAppAssetsRestore {
  const ProfileAppAssetsRestore({this.launchAnimationId, this.subtitleFontId});

  final String? launchAnimationId;
  final String? subtitleFontId;
}
