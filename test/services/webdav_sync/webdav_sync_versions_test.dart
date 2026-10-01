import 'dart:convert';
import 'dart:io';

import 'package:debrify/models/webdav_item.dart';
import 'package:debrify/services/webdav_protocol_client.dart';
import 'package:debrify/services/webdav_sync/webdav_sync_backup.dart';
import 'package:debrify/services/webdav_sync/webdav_sync_versions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  const first = 'snapshot-1790836200000-0123456789abcdef.debrify.enc';
  const second = 'snapshot-1790836300000-0123456789abcdef.debrify.enc';
  final directory = Uri.parse('https://example.test/dav/Debrify/versions/');

  test('version listing keeps only direct snapshots and sorts newest first', () {
    final rows = [
      '$directory$first',
      '$directory$second',
      '$directory$first',
      'https://other.test/dav/Debrify/versions/$second',
      '../$second',
      'nested/$second',
      'unrelated.enc',
    ];
    final xml =
        '<D:multistatus xmlns:D="DAV:">${rows.map((href) => '<D:response><D:href>$href</D:href><D:propstat><D:prop><D:getcontentlength>1234</D:getcontentlength></D:prop></D:propstat></D:response>').join()}</D:multistatus>';
    final versions = WebDavSyncVersions.parseListing(
      utf8.encode(xml),
      directory,
    );
    expect(versions.map((v) => v.fileName), [second, first]);
    expect(versions.first.sizeBytes, 1234);
    expect(versions.first.createdAt.isUtc, isTrue);
  });

  test('empty remote versions folder does not need to exist yet', () async {
    final client = WebDavProtocolClient(
      endpoint: Uri.parse('https://example.test/dav/'),
      credentials: const WebDavCredentials(
        username: 'alice',
        password: 'secret',
      ),
      client: MockClient((_) async => http.Response('', 404)),
    );
    expect(await WebDavSyncVersions(client).list(), isEmpty);
  });

  for (final corrupt in [false, true]) {
    test(
      'snapshot upload is create-only and verifies readback (corrupt: $corrupt)',
      () async {
        final scratch = await Directory.systemTemp.createTemp(
          'sync-version-test-',
        );
        addTearDown(() => scratch.delete(recursive: true));
        final file = File('${scratch.path}/snapshot.enc');
        await file.writeAsBytes([1, 2, 3, 4]);
        var barriers = 0;
        var uploaded = false;
        final client = WebDavProtocolClient(
          endpoint: Uri.parse('https://example.test/dav/'),
          credentials: const WebDavCredentials(
            username: 'alice',
            password: 'secret',
          ),
          client: MockClient((request) async {
            if (request.method == 'MKCOL') return http.Response('', 201);
            if (request.method == 'PUT') {
              uploaded = true;
              expect(request.headers['if-none-match'], '*');
              expect(request.bodyBytes, [1, 2, 3, 4]);
              expect(
                request.url.path,
                startsWith('/dav/Debrify/versions/snapshot-'),
              );
              return http.Response('', 201);
            }
            expect(request.method, 'GET');
            expect(uploaded, isTrue);
            return http.Response.bytes(corrupt ? [9] : [1, 2, 3, 4], 200);
          }),
        );
        final versions = WebDavSyncVersions(
          client,
          beforeSend: () async {
            barriers++;
          },
        );
        if (corrupt) {
          await expectLater(versions.upload(file, scratch), throwsStateError);
        } else {
          final result = await versions.upload(file, scratch);
          expect(WebDavSyncVersion.parse(result.fileName), isNotNull);
        }
        expect(barriers, greaterThanOrEqualTo(3));
        expect(
          await File('${scratch.path}/snapshot-readback.enc').exists(),
          isFalse,
        );
      },
    );
  }

  test('restore cannot request a path outside the snapshot folder', () async {
    final client = WebDavProtocolClient(
      endpoint: directory,
      credentials: const WebDavCredentials(
        username: 'alice',
        password: 'secret',
      ),
      client: MockClient((_) async => fail('Must reject before network')),
    );
    await expectLater(
      WebDavSyncVersions(client).download(
        WebDavSyncVersion(
          fileName: '../private',
          createdAt: DateTime.utc(2026),
        ),
        File('/unused'),
      ),
      throwsFormatException,
    );
  });

  const config = WebDavConfig(
    id: 'sync',
    name: 'Home',
    baseUrl: 'https://example.test/dav',
    username: 'alice',
    password: 'new-password',
  );
  final backup = WebDavSyncBackup(
    connection: {
      'endpoint': config.baseUrl,
      'folder': 'Debrify',
      'name': 'Home',
      'username': 'alice',
      'password': 'old-password',
      'passphrase': 'sync-secret',
      'enabled': false,
    },
    profileIds: const {'remote': 'backup-profile'},
    resourceIds: const {'resource': 'backup-resource'},
  );

  test(
    'snapshot restore refreshes credentials, keeps identities, and resumes sync',
    () {
      final restored = backup.forSnapshotRestore(
        config: config,
        folderPath: 'Debrify',
        syncPassphrase: 'sync-secret',
      );
      expect(restored.connection!['password'], 'new-password');
      expect(restored.connection!['enabled'], isTrue);
      expect(restored.profileIds, backup.profileIds);
      expect(restored.resourceIds, backup.resourceIds);
    },
  );

  test(
    'snapshot from a different folder or sync secret cannot be restored',
    () {
      expect(
        () => backup.forSnapshotRestore(
          config: config,
          folderPath: 'Other',
          syncPassphrase: 'sync-secret',
        ),
        throwsFormatException,
      );
      expect(
        () => backup.forSnapshotRestore(
          config: config,
          folderPath: 'Debrify',
          syncPassphrase: 'other-secret',
        ),
        throwsFormatException,
      );
    },
  );
}
