import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../utils/platform_util.dart';

/// The DEVICE media volume, for the player's volume swipe on phones and
/// tablets — the counterpart of the brightness swipe setting the real screen
/// brightness. Desktop keeps the player's own gain; televisions leave volume
/// to the remote.
abstract final class SystemVolume {
  static const MethodChannel _channel = MethodChannel('debrify/system_volume');

  /// Hand-held Android and iPhone/iPad.
  static bool get supported =>
      !kIsWeb &&
      !PlatformUtil.isTelevision &&
      (Platform.isAndroid || PlatformUtil.isIosMobile);

  /// 0..1, or null when it can't be read.
  static Future<double?> get() async {
    if (!supported) return null;
    try {
      final value = await _channel.invokeMethod<num>('get');
      return value?.toDouble().clamp(0.0, 1.0);
    } catch (_) {
      return null;
    }
  }

  static double? _pending;
  static bool _writing = false;

  /// Sets the volume (0..1). Calls during a drag coalesce: only the latest
  /// value is in flight, so a fast swipe never queues a backlog of writes.
  static Future<void> set(double value) async {
    if (!supported) return;
    _pending = value.clamp(0.0, 1.0);
    if (_writing) return;
    _writing = true;
    try {
      while (_pending != null) {
        final next = _pending!;
        _pending = null;
        try {
          await _channel.invokeMethod<void>('set', {'value': next});
        } catch (_) {
          // Optional control: the platform may refuse (Do Not Disturb).
        }
      }
    } finally {
      _writing = false;
    }
  }
}
