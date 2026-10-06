import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:debrify/services/startup_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class _Client extends MockClient {
  _Client(super.handler);
  bool closed = false;
  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  setUp(StartupConnection.reset);
  tearDown(StartupConnection.reset);

  test('airplane mode enters offline without issuing a request', () async {
    StartupConnection.connectivityOverride = () async => [
      ConnectivityResult.none,
    ];
    StartupConnection.clientOverride = () =>
        throw StateError('No HTTP allowed');
    expect(await StartupConnection.check(), isFalse);
  });

  test('launch callers share one reachability request', () async {
    var requests = 0;
    final client = _Client((request) async {
      requests++;
      expect(request.method, 'HEAD');
      return http.Response('', 503);
    });
    StartupConnection.connectivityOverride = () async => [
      ConnectivityResult.wifi,
    ];
    StartupConnection.clientOverride = () => client;
    expect(
      await Future.wait([StartupConnection.check(), StartupConnection.check()]),
      [true, true],
    );
    expect(requests, 1);
    expect(client.closed, isTrue);
  });

  test('Wi-Fi with no internet enters offline', () async {
    final client = _Client((_) async => throw const SocketException('offline'));
    StartupConnection.connectivityOverride = () async => [
      ConnectivityResult.wifi,
    ];
    StartupConnection.clientOverride = () => client;
    expect(await StartupConnection.check(), isFalse);
    expect(client.closed, isTrue);
  });

  test('a stalled request releases startup and closes its client', () async {
    final response = Completer<http.Response>();
    final client = _Client((_) => response.future);
    StartupConnection.connectivityOverride = () async => [
      ConnectivityResult.mobile,
    ];
    StartupConnection.clientOverride = () => client;
    expect(await StartupConnection.check(), isFalse);
    expect(client.closed, isTrue);
    response.complete(http.Response('', 200));
  });

  test(
    'a late platform reply cannot start HTTP after the launch deadline',
    () async {
      final transports = Completer<List<ConnectivityResult>>();
      var requests = 0;
      StartupConnection.connectivityOverride = () => transports.future;
      StartupConnection.clientOverride = () {
        requests++;
        return _Client((_) async => http.Response('', 200));
      };
      expect(await StartupConnection.check(), isFalse);
      transports.complete([ConnectivityResult.wifi]);
      await Future<void>.delayed(Duration.zero);
      expect(requests, 0);
    },
  );
}
