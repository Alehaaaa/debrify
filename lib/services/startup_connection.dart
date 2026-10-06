import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// A short launch-only reachability check. It runs alongside local bootstrap;
/// transfer and metadata services never need its answer to read local files.
class StartupConnection {
  StartupConnection._();
  static Future<bool>? _pending;
  static const deadline = Duration(milliseconds: 1200);

  @visibleForTesting
  static Future<List<ConnectivityResult>> Function()? connectivityOverride;
  @visibleForTesting
  static http.Client Function()? clientOverride;

  static Future<bool> check() => _pending ??= _check();

  @visibleForTesting
  static void reset() {
    _pending = null;
    connectivityOverride = null;
    clientOverride = null;
  }

  static Future<bool> _check() async {
    http.Client? client;
    bool finished = false;
    try {
      return await (() async {
        final transports =
            await (connectivityOverride?.call() ??
                Connectivity().checkConnectivity());
        if (transports.isEmpty ||
            transports.every((value) => value == ConnectivityResult.none)) {
          return false;
        }
        if (finished) return false;
        client = clientOverride?.call() ?? http.Client();
        final response = await client!.head(
          Uri.parse('https://v3-cinemeta.strem.io/manifest.json'),
        );
        // An HTTP error still proves there is a route to the internet.
        return response.statusCode >= 200 && response.statusCode < 600;
      })().timeout(deadline, onTimeout: () => false);
    } catch (_) {
      // Missing platform support is inconclusive: show the normal shell.
      // A network error after obtaining a client means offline at launch.
      return client == null;
    } finally {
      finished = true;
      client?.close();
    }
  }
}
