import 'dart:async';

import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart';

const _root = 'org.mpris.MediaPlayer2';
const _player = 'org.mpris.MediaPlayer2.Player';

/// Linux side of [MediaSessionService]: an MPRIS player on the session bus,
/// which is what desktop media widgets, `playerctl` and keyboard media keys
/// talk to. Fed the same update maps the other platforms get over their
/// method channel; commands come back in the same shape.
class MprisMediaSession {
  MprisMediaSession(this._onCommand);

  final void Function(Map<String, Object?> command) _onCommand;
  DBusClient? _client;
  _MprisObject? _object;
  Future<_MprisObject?>? _starting;

  Future<_MprisObject?> _ensure() => _starting ??= () async {
    try {
      final client = DBusClient.session();
      final object = _MprisObject(_onCommand);
      await client.requestName('$_root.debrify');
      await client.registerObject(object);
      _client = client;
      _object = object;
      return object;
    } catch (e) {
      // No session bus (a bare X session, a sandbox): nothing to drive.
      debugPrint('MPRIS: unavailable: $e');
      return null;
    }
  }();

  Future<void> update(Map<String, Object?> args) async {
    final object = await _ensure();
    await object?.apply(args);
  }

  Future<void> clear() async {
    await _object?.stop();
  }

  Future<void> dispose() async {
    await _client?.close();
    _client = null;
    _object = null;
    _starting = null;
  }
}

class _MprisObject extends DBusObject {
  _MprisObject(this._onCommand)
    : super(DBusObjectPath('/org/mpris/MediaPlayer2'));

  final void Function(Map<String, Object?> command) _onCommand;

  String _title = '';
  String? _subtitle;
  String? _artUrl;
  bool _playing = false;
  bool _stopped = true;
  int _positionUs = 0;
  int _lengthUs = 0;
  bool _canNext = false;
  bool _canPrevious = false;
  int _track = 0;

  DBusObjectPath get _trackId =>
      DBusObjectPath('/com/debrify/app/track/$_track');

  Future<void> apply(Map<String, Object?> args) async {
    final title = args['title'] as String? ?? _title;
    final subtitle = args['subtitle'] as String?;
    if (title != _title) _track++;
    final artPath = args['artworkPath'] as String?;
    final artUrl = artPath != null
        ? Uri.file(artPath).toString()
        : args['clearArtwork'] == true
        ? null
        : (args['artworkUrl'] as String? ?? _artUrl);
    final lengthUs = args['durationMs'] is num
        ? (args['durationMs'] as num).toInt() * 1000
        : _lengthUs;
    final metadataChanged =
        title != _title ||
        subtitle != _subtitle ||
        artUrl != _artUrl ||
        lengthUs != _lengthUs ||
        _stopped;
    _title = title;
    _subtitle = subtitle;
    _artUrl = artUrl;
    _lengthUs = lengthUs;
    if (args['positionMs'] is num) {
      _positionUs = (args['positionMs'] as num).toInt() * 1000;
    }
    final changed = <String, DBusValue>{};
    if (args['playing'] is bool && (args['playing'] != _playing || _stopped)) {
      _playing = args['playing'] as bool;
      changed['PlaybackStatus'] = _status;
    }
    _stopped = false;
    if (args['canNext'] is bool && args['canNext'] != _canNext) {
      _canNext = args['canNext'] as bool;
      changed['CanGoNext'] = DBusBoolean(_canNext);
    }
    if (args['canPrevious'] is bool && args['canPrevious'] != _canPrevious) {
      _canPrevious = args['canPrevious'] as bool;
      changed['CanGoPrevious'] = DBusBoolean(_canPrevious);
    }
    if (metadataChanged) changed['Metadata'] = _metadata;
    if (changed.isNotEmpty) {
      await emitPropertiesChanged(_player, changedProperties: changed);
    }
    if (args['seeked'] == true) {
      await emitSignal(_player, 'Seeked', [DBusInt64(_positionUs)]);
    }
  }

  Future<void> stop() async {
    _stopped = true;
    _playing = false;
    _title = '';
    _subtitle = null;
    _artUrl = null;
    await emitPropertiesChanged(
      _player,
      changedProperties: {'PlaybackStatus': _status, 'Metadata': _metadata},
    );
  }

  DBusValue get _status => DBusString(
    _stopped
        ? 'Stopped'
        : _playing
        ? 'Playing'
        : 'Paused',
  );

  DBusValue get _metadata => DBusDict.stringVariant({
    if (!_stopped) ...{
      'mpris:trackid': _trackId,
      'xesam:title': DBusString(_title),
      if (_subtitle != null) 'xesam:artist': DBusArray.string([_subtitle!]),
      if (_lengthUs > 0) 'mpris:length': DBusInt64(_lengthUs),
      if (_artUrl != null) 'mpris:artUrl': DBusString(_artUrl!),
    },
  });

  Map<String, DBusValue> get _rootProperties => {
    'CanQuit': const DBusBoolean(false),
    'CanRaise': const DBusBoolean(false),
    'HasTrackList': const DBusBoolean(false),
    'Identity': const DBusString('Nextup'),
    'DesktopEntry': const DBusString('debrify'),
    'SupportedUriSchemes': DBusArray.string(const []),
    'SupportedMimeTypes': DBusArray.string(const []),
  };

  Map<String, DBusValue> get _playerProperties => {
    'PlaybackStatus': _status,
    'Rate': const DBusDouble(1),
    'MinimumRate': const DBusDouble(1),
    'MaximumRate': const DBusDouble(1),
    'Metadata': _metadata,
    'Volume': const DBusDouble(1),
    'Position': DBusInt64(_positionUs),
    'CanGoNext': DBusBoolean(_canNext),
    'CanGoPrevious': DBusBoolean(_canPrevious),
    'CanPlay': DBusBoolean(!_stopped),
    'CanPause': DBusBoolean(!_stopped),
    'CanSeek': DBusBoolean(!_stopped && _lengthUs > 0),
    'CanControl': const DBusBoolean(true),
  };

  Map<String, DBusValue>? _propertiesOf(String interface) =>
      switch (interface) {
        _root => _rootProperties,
        _player => _playerProperties,
        _ => null,
      };

  @override
  Future<DBusMethodResponse> getProperty(String interface, String name) async {
    final value = _propertiesOf(interface)?[name];
    return value == null
        ? DBusMethodErrorResponse.unknownProperty()
        : DBusGetPropertyResponse(value);
  }

  @override
  Future<DBusMethodResponse> getAllProperties(String interface) async {
    final properties = _propertiesOf(interface);
    return properties == null
        ? DBusMethodErrorResponse.unknownInterface()
        : DBusGetAllPropertiesResponse(properties);
  }

  @override
  Future<DBusMethodResponse> setProperty(
    String interface,
    String name,
    DBusValue value,
  ) async => DBusMethodErrorResponse.propertyReadOnly();

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall call) async {
    if (call.interface == _root) {
      // Raise / Quit: advertised as unsupported, accepted as no-ops.
      return DBusMethodSuccessResponse();
    }
    if (call.interface != _player) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    switch (call.name) {
      case 'Play':
        _onCommand({'action': 'play'});
      case 'Pause':
      case 'Stop':
        _onCommand({'action': 'pause'});
      case 'PlayPause':
        _onCommand({'action': _playing ? 'pause' : 'play'});
      case 'Next':
        _onCommand({'action': 'next'});
      case 'Previous':
        _onCommand({'action': 'previous'});
      case 'Seek':
        final offset = call.values.firstOrNull;
        if (offset is DBusInt64) {
          _onCommand({'action': 'seekBy', 'offsetMs': offset.value ~/ 1000});
        }
      case 'SetPosition':
        final position = call.values.length > 1 ? call.values[1] : null;
        if (position is DBusInt64) {
          _onCommand({'action': 'seek', 'positionMs': position.value ~/ 1000});
        }
      case 'OpenUri':
        break;
      default:
        return DBusMethodErrorResponse.unknownMethod();
    }
    return DBusMethodSuccessResponse();
  }
}
