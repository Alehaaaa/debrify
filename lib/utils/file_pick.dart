import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// The pick-result shape the app was written against (file_picker ≤ 10),
/// rebuilt on the static file_picker 13 API. Call sites keep reading
/// `files.first`, `name`, `path`, `size` and, when asked for, `bytes`.
class PickedFiles {
  final List<PickedFile> files;
  const PickedFiles(this.files);
}

class PickedFile {
  final PlatformFile raw;

  /// Loaded up front only when the pick asked for `withData`.
  final Uint8List? bytes;

  /// In bytes; 0 when the platform can't tell.
  final int size;

  const PickedFile._(this.raw, this.bytes, this.size);

  String get name => raw.name;
  String? get path => raw.path;
  String? get extension => raw.extension;

  Future<Uint8List> readAsBytes() async => bytes ?? await raw.readAsBytes();

  /// The file's contents as a stream (what `withReadStream` used to supply).
  Stream<List<int>>? get readStream => raw.readAsByteStream();
}

class FilePick {
  const FilePick._();

  /// Returns null when the user cancels, like the old `pickFiles`.
  static Future<PickedFiles?> pickFiles({
    String? dialogTitle,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
  }) async {
    final List<PlatformFile> picked;
    if (allowMultiple) {
      picked = await FilePicker.pickFiles(
        dialogTitle: dialogTitle,
        type: type,
        allowedExtensions: allowedExtensions,
      );
    } else {
      final one = await FilePicker.pickFile(
        dialogTitle: dialogTitle,
        type: type,
        allowedExtensions: allowedExtensions,
      );
      picked = one == null ? const <PlatformFile>[] : <PlatformFile>[one];
    }
    if (picked.isEmpty) return null;
    return PickedFiles([
      for (final file in picked)
        PickedFile._(
          file,
          withData ? await file.readAsBytes() : null,
          file.lengthSync() ?? await file.length() ?? 0,
        ),
    ]);
  }
}
