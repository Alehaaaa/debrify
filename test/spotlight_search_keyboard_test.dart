import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:debrify/models/stremio_addon.dart';
import 'package:debrify/screens/search_screen.dart';
import 'package:debrify/services/main_page_bridge.dart';
import 'package:debrify/services/profiles/profile_runtime.dart';
import 'package:debrify/services/stremio_service.dart';
import 'package:debrify/services/storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Typing in Spotlight search auto-searches after a short pause. That search
/// clears the board before results stream in, which briefly leaves the hero
/// empty; the page used to drop to the Classic layout in that gap, rebuilding
/// the search field — the focused one unmounted and iOS closed the keyboard
/// as if Search had been pressed.
class _TempPaths extends PathProviderPlatform {
  _TempPaths(this.root);
  final Directory root;

  Future<String> _dir(String name) async =>
      (await Directory('${root.path}/$name').create(recursive: true)).path;

  @override
  Future<String?> getTemporaryPath() => _dir('tmp');

  @override
  Future<String?> getApplicationSupportPath() => _dir('support');

  @override
  Future<String?> getApplicationDocumentsPath() => _dir('documents');

  @override
  Future<String?> getApplicationCachePath() => _dir('cache');
}

void main() {
  testWidgets('auto-search while typing keeps the same field focused', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final root = Directory.systemTemp.createTempSync('search-keyboard-');
    final previousPaths = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _TempPaths(root);
    addTearDown(() {
      PathProviderPlatform.instance = previousPaths;
      root.deleteSync(recursive: true);
    });
    ProfileRuntime.debugReset();
    ProfileRuntime.initializeLegacy();
    MainPageBridge.setActiveTab('home');
    final previousStyle = StorageService.tvHomeStyleCached;
    addTearDown(() {
      StorageService.tvHomeStyleCached = previousStyle;
      MainPageBridge.setActiveTab(null);
      StremioService.instance.invalidateCache();
      ProfileRuntime.debugReset();
    });
    final addon = StremioAddon(
      id: 'keyboard-test',
      name: 'Keyboard test',
      baseUrl: 'https://keyboard.invalid',
      manifestUrl: 'https://keyboard.invalid/manifest.json',
      resources: ['catalog'],
      catalogs: [
        const StremioAddonCatalog(
          id: 'top',
          type: 'movie',
          name: 'Top',
          extraSupported: ['search'],
        ),
      ],
    );
    SharedPreferences.setMockInitialValues({
      'stremio_addons_v1': jsonEncode([addon.toJson()]),
      'tv_home_style': 'spotlight',
    });
    StorageService.tvHomeStyleCached = 'spotlight';
    StremioService.instance.invalidateCache();
    final metas = jsonEncode({
      'metas': [
        for (var i = 0; i < 6; i++)
          {'id': 'tt000000$i', 'type': 'movie', 'name': 'Movie $i'},
      ],
    });
    // The search stays in flight — like a real network — so frames render
    // while the board is cleared and its results haven't arrived.
    final searchReply = Completer<http.Response>();
    final client = MockClient((request) async {
      if (request.url.host != 'keyboard.invalid') {
        return http.Response('{}', 404);
      }
      if (request.url.path.contains('search=')) return searchReply.future;
      return http.Response(metas, 200);
    });

    await tester.runAsync(
      () => http.runWithClient(() async {
        await StremioService.instance.getCatalogAddons();
        await tester.pumpWidget(
          const MaterialApp(home: SearchScreen(isTelevision: false)),
        );
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }, () => client),
    );
    await tester.pump();

    await tester.tap(find.byIcon(Icons.search_rounded));
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    final field = find.byType(EditableText);
    expect(field, findsOneWidget);
    final focus = tester.widget<EditableText>(field).focusNode;
    final fieldElement = tester.element(field);
    expect(focus.hasFocus, isTrue);

    await tester.runAsync(
      () => http.runWithClient(() async {
        await tester.enterText(field, 'matrix');
        // Past the 450ms typing debounce (a real-time timer in this zone):
        // the auto-search runs and clears the board for its results.
        await Future<void>.delayed(const Duration(milliseconds: 700));
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }, () => client),
    );
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(field, findsOneWidget);
    // Still the SAME field, still focused: the keyboard never closed.
    expect(identical(tester.element(field), fieldElement), isTrue);
    expect(focus.hasFocus, isTrue);
    expect(tester.widget<EditableText>(field).controller.text, 'matrix');
    expect(tester.takeException(), isNull);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      searchReply.complete(http.Response('{"metas":[]}', 200));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
  });
}
