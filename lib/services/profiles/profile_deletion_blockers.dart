/// Fixed, user-presentable reasons a profile deletion was refused.
///
/// Only messages authored in this codebase are mapped. Anything else returns
/// null, so arbitrary exception text (paths, endpoints) never reaches logs or
/// the UI.
abstract final class ProfileDeletionBlockers {
  static const Map<String, String> _reasons = <String, String>{
    'Switch away before deleting this profile':
        'Switch to a different profile on this device first.',
    'Cannot delete the active profile':
        'Switch to a different profile on this device first.',
    'Active jobs must finish or be cancelled first':
        'This profile has downloads or recordings in progress. Finish or '
        'cancel them first.',
    'Shared connections must be transferred or revoked':
        'This profile still shares connections with other profiles.',
    'Owned connections need an explicit disposition':
        'Choose what to do with this profile\'s connections.',
    'Public files need an explicit retention choice':
        'Choose whether to keep this profile\'s downloaded files.',
    'At least one enabled managing Admin is required':
        'Another enabled Admin that can manage profiles must remain.',
    'Committed profile mutations require an Admin actor':
        'Only an Admin that can manage profiles can delete profiles.',
    'Profile management is not authorized':
        'Only an Admin that can manage profiles can delete profiles.',
    'WebDAV sync adoption requires an active Admin':
        'Switch this device to an Admin that can manage profiles and back '
        'up, so sync can finish removing a deleted profile.',
    'Managing profile session has ended':
        'Your profile session changed. Try again.',
    'Managing profile session changed':
        'Your profile session changed. Try again.',
  };

  /// The reason for [error], or null when it is not a known blocker.
  static String? describe(Object? error) {
    final message = switch (error) {
      final StateError error => error.message,
      final Exception error => _exceptionMessage(error),
      _ => null,
    };
    return message == null ? null : _reasons[message];
  }

  static String? _exceptionMessage(Exception error) {
    final text = error.toString();
    for (final key in _reasons.keys) {
      if (text.endsWith(key)) return key;
    }
    return null;
  }
}
