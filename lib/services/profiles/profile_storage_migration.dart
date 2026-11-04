import 'dart:io';

import 'package:path/path.dart' as p;

import '../../utils/app_storage.dart';
import 'profile_storage_paths.dart';

/// Moves the old user-visible `Documents/profiles` tree into app data.
///
/// This is deliberately idempotent: an interruption leaves the source in
/// place, and the next launch verifies/copies it again before removing it.
class ProfileStorageMigration {
  ProfileStorageMigration._();

  static Future<void> migrateDocumentsProfiles() async {
    final legacyRoot = Directory(
      p.join((await AppStorage.documents()).path, 'profiles'),
    );
    final dataRoot = Directory(
      p.join((await ProfileStoragePaths.profileDataRoot()).path, 'profiles'),
    );
    if (p.normalize(legacyRoot.absolute.path) ==
            p.normalize(dataRoot.absolute.path) ||
        !await legacyRoot.exists()) {
      return;
    }
    await dataRoot.create(recursive: true);
    await for (final entity in legacyRoot.list(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final relative = p.relative(entity.path, from: legacyRoot.path);
      final destination = File(p.join(dataRoot.path, relative));
      await destination.parent.create(recursive: true);
      if (!await destination.exists() ||
          await destination.length() != await entity.length()) {
        await entity.copy(destination.path);
      }
      // A length check makes the migration retryable without replacing a
      // newer target file created after a previous partial migration.
      if (await destination.length() != await entity.length()) {
        throw FileSystemException(
          'Profile data migration verification failed',
          entity.path,
        );
      }
    }
    await legacyRoot.delete(recursive: true);
  }
}
