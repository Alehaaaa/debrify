import 'dart:io';

import 'package:path/path.dart' as p;

import '../../utils/app_storage.dart';
import 'profile_runtime.dart';

class ProfileStoragePaths {
  ProfileStoragePaths._();

  /// Private profile files belong in the native application-data location,
  /// never in user-visible Documents. `support` maps to Application Support
  /// on Apple platforms, AppData on desktop and the app-private files area on
  /// Android (with the existing cache fallback on physical tvOS).
  static Future<Directory> profileDataRoot() => AppStorage.support();

  static Future<String> documentsFile(String relativePath) async =>
      _resolve(await profileDataRoot(), 'documents', relativePath);

  static Future<String> supportFile(String relativePath) async =>
      _resolve(await AppStorage.support(), 'support', relativePath);

  static Future<String> cacheFile(String relativePath) async =>
      _resolve(await AppStorage.cache(), 'cache', relativePath);

  static Future<String> documentsDirectory() async {
    final root = await profileDataRoot();
    if (ProfileRuntime.mode == ProfileRuntimeMode.legacyCompatibility) {
      return root.path;
    }
    final directory = ProfileRuntime.capture().storageDirectory(
      root,
      'documents',
    );
    await directory.create(recursive: true);
    return directory.path;
  }

  static Future<String> _resolve(
    Directory root,
    String area,
    String relativePath,
  ) async {
    final normalized = p.normalize(relativePath);
    if (p.isAbsolute(normalized) ||
        normalized == '..' ||
        normalized.startsWith('../')) {
      throw ArgumentError.value(relativePath, 'relativePath', 'Unsafe path');
    }
    if (ProfileRuntime.mode == ProfileRuntimeMode.legacyCompatibility) {
      return p.join(root.path, normalized);
    }
    final file = ProfileRuntime.capture().fileIn(root, area, normalized);
    await file.parent.create(recursive: true);
    return file.path;
  }
}
