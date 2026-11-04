import 'dart:io';
import 'dart:typed_data';

import 'package:debrify/services/relay_clip_file.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Uint8List box(String type, List<int> payload) {
  final out = ByteData(8 + payload.length);
  out.setUint32(0, 8 + payload.length);
  final bytes = out.buffer.asUint8List();
  bytes.setRange(4, 8, type.codeUnits);
  bytes.setRange(8, bytes.length, payload);
  return bytes;
}

List<int> u32(int v) => (ByteData(4)..setUint32(0, v)).buffer.asUint8List();
List<int> u64(int v) => (ByteData(8)..setUint64(0, v)).buffer.asUint8List();

/// ffmpeg-shaped fragmented MP4: video track 1 at [timescale], one fragment
/// per [fragmentSeconds], audio track 2 alongside.
Uint8List fragmentedMp4({
  required int fragments,
  int timescale = 12800,
  int fragmentSeconds = 2,
}) {
  Uint8List trak(int id, String handler, int scale) => box('trak', [
    ...box('tkhd', [0, 0, 0, 3, ...u32(0), ...u32(0), ...u32(id)]),
    ...box('mdia', [
      ...box('mdhd', [0, 0, 0, 0, ...u32(0), ...u32(0), ...u32(scale)]),
      ...box('hdlr', [0, 0, 0, 0, ...u32(0), ...handler.codeUnits]),
    ]),
  ]);
  Uint8List traf(int id, int decodeTime) => box('traf', [
    ...box('tfhd', [0, 0, 0, 0x39, ...u32(id)]),
    ...box('tfdt', [1, 0, 0, 0, ...u64(decodeTime)]),
  ]);
  return Uint8List.fromList([
    ...box('ftyp', 'isomiso6'.codeUnits),
    ...box('moov', [...trak(1, 'vide', timescale), ...trak(2, 'soun', 44100)]),
    for (var i = 0; i < fragments; i++) ...[
      ...box('moof', [
        ...traf(1, i * fragmentSeconds * timescale),
        ...traf(2, i * fragmentSeconds * 44100),
      ]),
      ...box('mdat', List.filled(5000, i)),
    ],
    ...box('mfra', List.filled(16, 0)),
  ]);
}

/// Top-level box types in [bytes].
List<String> topLevel(Uint8List bytes) {
  final types = <String>[];
  var offset = 0;
  while (offset + 8 <= bytes.length) {
    final size = ByteData.sublistView(bytes, offset).getUint32(0);
    types.add(String.fromCharCodes(bytes, offset + 4, offset + 8));
    offset += size;
  }
  expect(offset, bytes.length, reason: 'file ends on a box boundary');
  return types;
}

http.Client streaming(Uint8List body, {int chunk = 777}) =>
    MockClient.streaming((request, _) async {
      Stream<List<int>> chunks() async* {
        for (var i = 0; i < body.length; i += chunk) {
          yield body.sublist(i, (i + chunk).clamp(0, body.length));
        }
      }

      return http.StreamedResponse(chunks(), 200);
    });

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('relay_clip'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('keeps whole fragments up to the preview length', () async {
    final file = File('${dir.path}/clip.mp4');
    final ok = await RelayClipFile.download(
      Uri.parse('https://relay.example/tunnel'),
      file,
      maxDuration: const Duration(seconds: 10),
      client: streaming(fragmentedMp4(fragments: 20)),
    );
    expect(ok, true);
    // Fragments start at 0, 2, 4, 6, 8 s; the one at 10 s is past the cut.
    expect(topLevel(file.readAsBytesSync()), [
      'ftyp',
      'moov',
      for (var i = 0; i < 5; i++) ...['moof', 'mdat'],
    ]);
  });

  test('a short stream is saved whole, without its stream-wide index', () async {
    final file = File('${dir.path}/clip.mp4');
    final ok = await RelayClipFile.download(
      Uri.parse('https://relay.example/tunnel'),
      file,
      maxDuration: const Duration(seconds: 120),
      client: streaming(fragmentedMp4(fragments: 3), chunk: 64),
    );
    expect(ok, true);
    expect(topLevel(file.readAsBytesSync()), [
      'ftyp',
      'moov',
      for (var i = 0; i < 3; i++) ...['moof', 'mdat'],
    ]);
  });

  test('an empty tunnel leaves no file behind', () async {
    final file = File('${dir.path}/clip.mp4');
    final ok = await RelayClipFile.download(
      Uri.parse('https://relay.example/tunnel'),
      file,
      maxDuration: const Duration(seconds: 120),
      client: streaming(Uint8List(0)),
    );
    expect(ok, false);
    expect(file.existsSync(), false);
  });
}
