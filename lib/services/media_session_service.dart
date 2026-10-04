import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'debrify_image_cache.dart';
import 'media_session_mpris.dart';

/// What the OS media controls can ask the player to do.
abstract class MediaSessionHandler {
  void play();
  void pause();
  void next();
  void previous();
  void seekTo(Duration position);
  void seekBy(Duration offset);
}

/// Publishes the in-app player's title, poster and progress to the OS media
/// controls — Android's media session and notification, iOS/macOS Now
/// Playing, Windows' media overlay (SMTC), Linux MPRIS — and routes their
/// buttons (headset, Bluetooth, keyboard media keys, lock screen) back to the
/// player.
///
/// One player owns the session at a time; the last to [attach] wins and only
/// its own [detach] clears it, so a player closing behind a newer one never
/// wipes the newer one's controls.
class MediaSessionService {
  MediaSessionService._();
  static final MediaSessionService instance = MediaSessionService._();

  static const MethodChannel _channel = MethodChannel('debrify/media_session');

  /// Position updates are throttled to this; the OS extrapolates in between
  /// from the play rate, so the seek bar still moves smoothly.
  static const Duration _positionInterval = Duration(seconds: 5);

  Object? _owner;
  MediaSessionHandler? _handler;
  bool _channelReady = false;
  MprisMediaSession? _mpris;

  String _title = '';
  String? _subtitle;
  String? _artworkUrl;
  int _artworkGeneration = 0;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _canNext = false;
  bool _canPrevious = false;
  DateTime _lastPositionSent = DateTime.fromMillisecondsSinceEpoch(0);

  /// Tests drive the method-channel path on any host.
  @visibleForTesting
  static bool debugForceChannel = false;

  static bool get _supported {
    if (debugForceChannel) return true;
    if (kIsWeb || Platform.environment.containsKey('FLUTTER_TEST')) {
      return false;
    }
    return Platform.isAndroid ||
        Platform.isIOS ||
        Platform.isMacOS ||
        Platform.isWindows ||
        Platform.isLinux;
  }

  static bool get _useMpris => !debugForceChannel && Platform.isLinux;

  void attach(Object owner, MediaSessionHandler handler) {
    if (!_supported) return;
    _owner = owner;
    _handler = handler;
    if (_useMpris) {
      _mpris ??= MprisMediaSession(_onCommand);
    } else if (!_channelReady) {
      _channelReady = true;
      _channel.setMethodCallHandler(_onCall);
    }
  }

  void detach(Object owner) {
    if (!identical(owner, _owner)) return;
    _owner = null;
    _handler = null;
    _title = '';
    _subtitle = null;
    _artworkUrl = null;
    _artworkGeneration++;
    _playing = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    if (_useMpris) {
      unawaited(_mpris?.clear());
      return;
    }
    unawaited(_invoke('clear'));
  }

  /// What is playing. The poster is fetched (through the shared image cache,
  /// so a downloaded title's art works offline) and sent once it arrives.
  void setMetadata(
    Object owner, {
    required String title,
    String? subtitle,
    String? artworkUrl,
  }) {
    if (!identical(owner, _owner)) return;
    final artwork = artworkUrl?.trim().isEmpty ?? true
        ? null
        : artworkUrl!.startsWith('//')
        ? 'https:$artworkUrl'
        : artworkUrl;
    if (title == _title && subtitle == _subtitle && artwork == _artworkUrl) {
      return;
    }
    final artworkChanged = artwork != _artworkUrl;
    _title = title;
    _subtitle = subtitle;
    _artworkUrl = artwork;
    _push(clearArtwork: artworkChanged && artwork == null);
    if (artworkChanged && artwork != null) {
      unawaited(_sendArtwork(artwork, ++_artworkGeneration));
    }
  }

  /// Play state and progress. Cheap to call on every position tick: only a
  /// change of state, a seek, or every [_positionInterval] reaches the OS.
  void setPlayback(
    Object owner, {
    required bool playing,
    required Duration position,
    required Duration duration,
    bool canNext = false,
    bool canPrevious = false,
  }) {
    if (!identical(owner, _owner)) return;
    final now = DateTime.now();
    // Where the OS thinks playback is by now; a jump away from it is a seek.
    final expected = _playing
        ? _position + now.difference(_lastPositionSent)
        : _position;
    final jumped = (position - expected).abs() > const Duration(seconds: 2);
    final changed =
        playing != _playing ||
        duration != _duration ||
        canNext != _canNext ||
        canPrevious != _canPrevious ||
        jumped;
    _playing = playing;
    _duration = duration;
    _canNext = canNext;
    _canPrevious = canPrevious;
    if (!changed && now.difference(_lastPositionSent) < _positionInterval) {
      return;
    }
    _position = position;
    _push(seeked: jumped);
  }

  void _push({bool clearArtwork = false, bool seeked = false}) {
    if (_owner == null || _title.isEmpty) return;
    _lastPositionSent = DateTime.now();
    final args = <String, Object?>{
      'title': _title,
      'subtitle': _subtitle,
      'artworkUrl': _artworkUrl,
      'playing': _playing,
      'positionMs': _position.inMilliseconds,
      'durationMs': _duration.inMilliseconds,
      'rate': 1.0,
      'canNext': _canNext,
      'canPrevious': _canPrevious,
      if (clearArtwork) 'clearArtwork': true,
      if (seeked) 'seeked': true,
    };
    if (_useMpris) {
      unawaited(_mpris?.update(args));
    } else {
      unawaited(_invoke('update', args));
    }
  }

  Future<void> _sendArtwork(String url, int generation) async {
    Uint8List? bytes;
    String? localPath;
    try {
      final file = await DebrifyImageCache.manager
          .getSingleFile(url)
          .timeout(const Duration(seconds: 15));
      localPath = file.path;
      bytes = await file.readAsBytes();
    } catch (_) {
      return;
    }
    if (generation != _artworkGeneration || _owner == null) return;
    final args = <String, Object?>{
      'title': _title,
      'subtitle': _subtitle,
      'artworkUrl': _artworkUrl,
      'artworkPath': localPath,
      'artwork': bytes,
    };
    if (_useMpris) {
      unawaited(_mpris?.update(args));
    } else {
      unawaited(_invoke('update', args));
    }
  }

  Future<void> _invoke(String method, [Object? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      // A platform without the native side: nothing to drive.
    } catch (e) {
      debugPrint('MediaSession: $method failed: $e');
    }
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method == 'command' && call.arguments is Map) {
      _onCommand(Map<String, Object?>.from(call.arguments as Map));
    }
    return null;
  }

  void _onCommand(Map<String, Object?> command) {
    final handler = _handler;
    if (handler == null) return;
    switch (command['action']) {
      case 'play':
        handler.play();
      case 'pause':
        handler.pause();
      case 'toggle':
        _playing ? handler.pause() : handler.play();
      case 'next':
        handler.next();
      case 'previous':
        handler.previous();
      case 'seek':
        final ms = command['positionMs'];
        if (ms is num) handler.seekTo(Duration(milliseconds: ms.toInt()));
      case 'seekBy':
        final ms = command['offsetMs'];
        if (ms is num) handler.seekBy(Duration(milliseconds: ms.toInt()));
    }
  }

  @visibleForTesting
  void handleCommandForTesting(Map<String, Object?> command) =>
      _onCommand(command);
}
