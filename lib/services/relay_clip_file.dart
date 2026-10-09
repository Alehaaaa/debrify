import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Saves the start of a Cobalt relay tunnel as a local MP4 file.
///
/// A tunnel is ffmpeg's fragmented MP4 (`ftyp`, `moov`, then `moof`+`mdat`
/// pairs, each starting on a video keyframe) streamed live without byte-range
/// support. AVFoundation cannot open that over HTTP, but it reads the same
/// bytes from disk. Cutting between fragments keeps the prefix a valid file,
/// so only as much as [maxDuration] needs is downloaded.
class RelayClipFile {
  RelayClipFile._();

  /// Writes ftyp + moov + every complete fragment that starts before
  /// [maxDuration] to [destination]. True when at least one fragment was
  /// written; on false the destination is deleted.
  static Future<bool> download(
    Uri url,
    File destination, {
    required Duration maxDuration,
    int maxBytes = 160 * 1024 * 1024,
    Duration timeout = const Duration(seconds: 90),
    http.Client? client,
  }) async {
    final transport = client ?? http.Client();
    final sink = destination.openWrite();
    final parser = _FragmentedMp4Prefix(maxDuration);
    var written = 0;
    var fragments = 0;
    StreamSubscription<List<int>>? subscription;
    try {
      final response = await transport
          .send(http.Request('GET', url))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return false;
      final done = Completer<void>();
      final deadline = Timer(timeout, () {
        if (!done.isCompleted) done.complete();
      });
      subscription = response.stream.listen(
        (chunk) {
          if (done.isCompleted) return;
          for (final box in parser.add(chunk)) {
            sink.add(box.bytes);
            written += box.bytes.length;
            if (box.fragment) fragments++;
          }
          if (parser.finished || written >= maxBytes) done.complete();
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        cancelOnError: true,
      );
      await done.future;
      deadline.cancel();
      return fragments > 0;
    } catch (e) {
      debugPrint('RelayClipFile: download failed — $e');
      return false;
    } finally {
      await subscription?.cancel();
      await sink.close();
      if (client == null) transport.close();
      if (fragments == 0 && await destination.exists()) {
        await destination.delete();
      }
    }
  }
}

class _Box {
  const _Box(this.bytes, {this.fragment = false});
  final Uint8List bytes;

  /// A complete moof+mdat pair.
  final bool fragment;
}

/// Incremental top-level box splitter that keeps whole fragments only.
class _FragmentedMp4Prefix {
  _FragmentedMp4Prefix(this.maxDuration);

  final Duration maxDuration;

  /// Unparsed bytes. Only materialized once [_need] bytes are available, so
  /// a multi-megabyte `mdat` isn't re-copied for every network chunk.
  final _unparsed = BytesBuilder(copy: false);
  int _need = 16;
  Uint8List? _moof;
  bool _sawHeader = false;
  int? _videoTrack;
  int? _videoTimescale;
  bool finished = false;

  List<_Box> add(List<int> chunk) {
    final out = <_Box>[];
    if (finished) return out;
    _unparsed.add(chunk);
    if (_unparsed.length < _need) return out;
    final data = _unparsed.takeBytes();
    var offset = 0;
    _need = 16;
    while (!finished) {
      final header = _boxHeader(data, offset);
      if (header == null) break;
      final (size, type) = header;
      if (size == 0) {
        // "Extends to end of file": not something a live remux can bound.
        finished = true;
        break;
      }
      if (offset + size > data.length) {
        _need = size;
        break;
      }
      final box = Uint8List.sublistView(data, offset, offset + size);
      offset += size;
      switch (type) {
        case 'ftyp':
          out.add(_Box(Uint8List.fromList(box)));
        case 'moov':
          _readMoov(box);
          _sawHeader = true;
          out.add(_Box(Uint8List.fromList(box)));
        case 'moof':
          final start = _sawHeader ? _fragmentStart(box) : null;
          if (!_sawHeader || (start != null && start >= maxDuration)) {
            finished = true;
          } else {
            _moof = Uint8List.fromList(box);
          }
        case 'mdat':
          final moof = _moof;
          _moof = null;
          if (moof != null) {
            final pair = BytesBuilder(copy: false)
              ..add(moof)
              ..add(box);
            out.add(_Box(pair.takeBytes(), fragment: true));
          }
        case 'mfra':
          // Random-access index for the whole stream; its offsets would point
          // past a prefix. The prefix plays without it.
          finished = true;
        default:
          if (!_sawHeader) out.add(_Box(Uint8List.fromList(box)));
      }
    }
    if (!finished && offset < data.length) {
      _unparsed.add(Uint8List.sublistView(data, offset));
    }
    return out;
  }

  static (int, String)? _boxHeader(Uint8List data, int offset) {
    if (offset + 8 > data.length) return null;
    final view = ByteData.sublistView(data, offset);
    var size = view.getUint32(0);
    final type = String.fromCharCodes(data, offset + 4, offset + 8);
    if (size == 1) {
      if (offset + 16 > data.length) return null;
      size = view.getUint64(8);
    } else if (size != 0 && size < 8) {
      return (0, type);
    }
    return (size, type);
  }

  /// Children of [box] (skipping its [skip]-byte header) as (type, payload).
  static Iterable<(String, Uint8List)> _children(Uint8List box, int skip) sync* {
    var offset = skip;
    while (true) {
      final header = _boxHeader(box, offset);
      if (header == null) return;
      final (size, type) = header;
      if (size < 8 || offset + size > box.length) return;
      yield (type, Uint8List.sublistView(box, offset, offset + size));
      offset += size;
    }
  }

  void _readMoov(Uint8List moov) {
    for (final (type, trak) in _children(moov, 8)) {
      if (type != 'trak') continue;
      int? trackId;
      int? timescale;
      String? handler;
      for (final (childType, child) in _children(trak, 8)) {
        if (childType == 'tkhd') {
          final view = ByteData.sublistView(child);
          trackId = view.getUint32(child[8] == 1 ? 28 : 20);
        } else if (childType == 'mdia') {
          for (final (mdiaType, mdiaChild) in _children(child, 8)) {
            final view = ByteData.sublistView(mdiaChild);
            if (mdiaType == 'mdhd') {
              timescale = view.getUint32(mdiaChild[8] == 1 ? 28 : 20);
            } else if (mdiaType == 'hdlr' && mdiaChild.length >= 20) {
              handler = String.fromCharCodes(mdiaChild, 16, 20);
            }
          }
        }
      }
      if (handler == 'vide' && trackId != null && (timescale ?? 0) > 0) {
        _videoTrack = trackId;
        _videoTimescale = timescale;
        return;
      }
    }
  }

  /// Decode time of the video track at the start of [moof].
  Duration? _fragmentStart(Uint8List moof) {
    final track = _videoTrack;
    final timescale = _videoTimescale;
    if (track == null || timescale == null) return null;
    for (final (type, traf) in _children(moof, 8)) {
      if (type != 'traf') continue;
      int? trackId;
      int? decodeTime;
      for (final (childType, child) in _children(traf, 8)) {
        final view = ByteData.sublistView(child);
        if (childType == 'tfhd' && child.length >= 16) {
          trackId = view.getUint32(12);
        } else if (childType == 'tfdt' && child.length >= 16) {
          decodeTime = child[8] == 1 && child.length >= 20
              ? view.getUint64(12)
              : view.getUint32(12);
        }
      }
      if (trackId == track && decodeTime != null) {
        return Duration(microseconds: decodeTime * 1000000 ~/ timescale);
      }
    }
    return null;
  }
}
