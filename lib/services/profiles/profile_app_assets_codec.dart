import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Wire format for device-level assets that travel with a profile package:
/// imported subtitle fonts, the selected imported launch animation and the
/// synced app-level settings.
///
/// Compatibility boundary: assets live in the optional profile-record field
/// [field], never in `filesSection` or a new section. Previous builds validate
/// every `filesSection` key against the `engines/` grammar, reject unknown
/// sections, and cap strings outside sections at 4 MiB, but they ignore an
/// unknown profile field. Data is therefore split into [chunkChars] strings so
/// an older build still imports the rest of the package.
abstract final class ProfileAppAssetsCodec {
  static const String field = 'appAssets';
  static const String fontPrefix = 'assets/subtitle-fonts/';
  static const String launchPrefix = 'assets/launch-animations/';
  static const String appSettingsPath = 'assets/app-settings/v1';

  static const int chunkChars = 3 * 1024 * 1024;
  static const int maxFontBytes = 4 * 1024 * 1024;
  static const int maxLaunchAnimationBytes = 10 * 1024 * 1024;
  static const int maxAppSettingsBytes = 256 * 1024;
  static const int maxTotalBytes = 64 * 1024 * 1024;
  static const int maxEntries = 128;

  static final RegExp _fontPath = RegExp(
    r'^assets/subtitle-fonts/custom_[A-Za-z0-9_-]{1,80}$',
  );
  static final RegExp _launchPath = RegExp(
    r'^assets/launch-animations/[a-f0-9]{32}$',
  );

  static bool isAllowedPath(String path) =>
      _fontPath.hasMatch(path) ||
      _launchPath.hasMatch(path) ||
      path == appSettingsPath;

  static int maxBytesFor(String path) {
    if (path.startsWith(launchPrefix)) return maxLaunchAnimationBytes;
    if (path == appSettingsPath) return maxAppSettingsBytes;
    return maxFontBytes;
  }

  static Future<Map<String, Object?>> encode(
    List<int> bytes, {
    Map<String, Object?> metadata = const <String, Object?>{},
  }) async {
    final encoded = base64Encode(bytes);
    return <String, Object?>{
      ...metadata,
      'encoding': 'base64-chunks',
      'bytes': bytes.length,
      'sha256': await _hash(bytes),
      'chunks': <String>[
        for (var start = 0; start < encoded.length; start += chunkChars)
          encoded.substring(
            start,
            start + chunkChars > encoded.length
                ? encoded.length
                : start + chunkChars,
          ),
      ],
    };
  }

  /// Authenticates one asset record and returns its bytes.
  static Future<Uint8List> decode(String path, Object? record) async {
    if (!isAllowedPath(path) ||
        record is! Map ||
        record['encoding'] != 'base64-chunks' ||
        record['bytes'] is! int ||
        record['sha256'] is! String ||
        record['chunks'] is! List) {
      throw const FormatException('Invalid portable app asset');
    }
    final claimed = record['bytes'] as int;
    final maxBytes = maxBytesFor(path);
    final chunks = record['chunks'] as List;
    if (claimed < 0 ||
        claimed > maxBytes ||
        chunks.length > (((maxBytes + 2) ~/ 3) * 4) ~/ chunkChars + 1 ||
        chunks.any((chunk) => chunk is! String || chunk.length > chunkChars)) {
      throw const FormatException('Portable app asset exceeds limit');
    }
    late final Uint8List bytes;
    try {
      bytes = base64Decode(chunks.cast<String>().join());
    } on FormatException {
      throw const FormatException('Portable app asset is not valid base64');
    }
    if (bytes.length != claimed || await _hash(bytes) != record['sha256']) {
      throw const FormatException('Portable app asset digest mismatch');
    }
    return bytes;
  }

  /// Validates the whole optional field as found on a profile record.
  static Future<void> validate(Object? field) async {
    if (field == null) return;
    if (field is! Map || field.length > maxEntries) {
      throw const FormatException('Invalid portable app assets');
    }
    var total = 0;
    for (final entry in field.entries) {
      final path = entry.key;
      if (path is! String) {
        throw const FormatException('Invalid portable app asset path');
      }
      total += (await decode(path, entry.value)).length;
      if (total > maxTotalBytes) {
        throw const FormatException('Portable app assets exceed limit');
      }
    }
  }

  static Future<String> _hash(List<int> bytes) async =>
      base64UrlEncode((await Sha256().hash(bytes)).bytes).replaceAll('=', '');
}
