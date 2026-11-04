import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:xml/xml.dart';

import '../webdav_backup_transport.dart';
import '../transfer/transfer_io.dart';
import '../webdav_protocol_client.dart';

final class WebDavSyncVersion {
  const WebDavSyncVersion({
    required this.fileName,
    required this.createdAt,
    this.sizeBytes,
  });
  final String fileName;
  final DateTime createdAt;
  final int? sizeBytes;

  static final filePattern = RegExp(
    r'^snapshot-(\d{13})-([a-f0-9]{16})\.debrify\.enc$',
  );
  static WebDavSyncVersion? parse(String name, {int? sizeBytes}) {
    final match = filePattern.firstMatch(name);
    if (match == null) return null;
    return WebDavSyncVersion(
      fileName: name,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        int.parse(match[1]!),
        isUtc: true,
      ),
      sizeBytes: sizeBytes,
    );
  }
}

/// Immutable encrypted snapshots, kept separately from the live sync journal.
/// The caller owns the client and supplies a captured Admin-session barrier.
final class WebDavSyncVersions {
  WebDavSyncVersions(
    this.client, {
    this.folderPath = 'Nextup',
    this.beforeSend,
  });
  final WebDavProtocolClient client;
  final String folderPath;
  final Future<void> Function()? beforeSend;
  String get directory => '$folderPath/versions';

  Future<List<WebDavSyncVersion>> list() async {
    if (!(await client.exists(
      path: directory,
      collection: true,
      beforeSend: beforeSend,
    )).exists) {
      return [];
    }
    final result = await client.propfind(
      path: directory,
      depth: 1,
      collection: true,
      beforeSend: beforeSend,
      body:
          '<?xml version="1.0"?><D:propfind xmlns:D="DAV:"><D:prop><D:resourcetype/><D:getcontentlength/></D:prop></D:propfind>',
    );
    return parseListing(
      result.bytes,
      client.uriForPath(directory, collection: true),
    );
  }

  static List<WebDavSyncVersion> parseListing(
    List<int> bytes,
    Uri directoryUri,
  ) {
    final document = XmlDocument.parse(utf8.decode(bytes));
    final result = <String, WebDavSyncVersion>{};
    for (final response in document.descendants.whereType<XmlElement>().where(
      (e) => e.name.local == 'response',
    )) {
      String? text(String name) => response.descendants
          .whereType<XmlElement>()
          .where((e) => e.name.local == name)
          .firstOrNull
          ?.innerText;
      final href = text('href');
      if (href == null ||
          response.descendants.whereType<XmlElement>().any(
            (e) => e.name.local == 'collection',
          )) {
        continue;
      }
      final uri = directoryUri.resolve(href);
      if (uri.origin != directoryUri.origin ||
          uri.hasQuery ||
          uri.hasFragment) {
        continue;
      }
      final name = uri.pathSegments.last;
      // Accept only direct children of this exact folder. Never follow paths
      // supplied by an untrusted listing to another account or remote folder.
      if (uri != directoryUri.resolve(name)) continue;
      final version = WebDavSyncVersion.parse(
        name,
        sizeBytes: int.tryParse(text('getcontentlength') ?? ''),
      );
      if (version != null) result[name] = version;
    }
    return result.values.toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }

  Future<WebDavSyncVersion> upload(File encrypted, Directory scratch) async {
    await client.ensureCollection(directory, beforeSend: beforeSend);
    final random = Random.secure();
    final suffix = List.generate(
      8,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final version = WebDavSyncVersion.parse(
      'snapshot-${DateTime.now().toUtc().millisecondsSinceEpoch}-$suffix.debrify.enc',
    )!;
    final path = '$directory/${version.fileName}';
    final uploaded = await client.uploadFile(
      path: path,
      file: encrypted,
      maxBytes: TransferIo.maxFileBytes,
      ifNoneMatch: '*',
      beforeSend: beforeSend,
    );
    if (uploaded.statusCode != HttpStatus.created) {
      throw StateError(
        'The server did not confirm creation of a new snapshot.',
      );
    }
    final verify = File('${scratch.path}/snapshot-readback.enc');
    try {
      await client.downloadToFile(
        path: path,
        destination: verify,
        maxBytes: TransferIo.maxFileBytes,
        beforeSend: beforeSend,
      );
      if (await WebDavBackupTransport.sha256File(encrypted) !=
          await WebDavBackupTransport.sha256File(verify)) {
        throw StateError(
          'Snapshot verification failed. The uploaded file was left on the server; do not restore it.',
        );
      }
      return version;
    } finally {
      if (await verify.exists()) await verify.delete();
    }
  }

  Future<void> download(WebDavSyncVersion version, File destination) async {
    if (WebDavSyncVersion.parse(version.fileName) == null) {
      throw const FormatException('Invalid snapshot name');
    }
    if ((version.sizeBytes ?? 0) > TransferIo.maxFileBytes) {
      throw const FormatException('Snapshot is too large');
    }
    await client.downloadToFile(
      path: '$directory/${version.fileName}',
      destination: destination,
      maxBytes: TransferIo.maxFileBytes,
      beforeSend: beforeSend,
    );
  }
}
