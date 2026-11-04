import 'dart:async';
import 'dart:convert';

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
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final width in [390.0, 1280.0]) {
    testWidgets('search moves continuously without reflow at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
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
        id: 'motion-test',
        name: 'Motion test',
        baseUrl: 'https://motion.invalid',
        manifestUrl: 'https://motion.invalid/manifest.json',
        resources: ['catalog'],
        catalogs: [
          const StremioAddonCatalog(id: 'slow', type: 'movie', name: 'Slow'),
        ],
      );
      SharedPreferences.setMockInitialValues({
        'stremio_addons_v1': jsonEncode([addon.toJson()]),
        'tv_home_style': 'spotlight',
      });
      StorageService.tvHomeStyleCached = 'spotlight';
      StremioService.instance.invalidateCache();
      // Keep catalog loading independent of the search interaction.
      final catalog = Completer<http.Response>();
      final client = MockClient(
        (request) async => request.url.host == 'motion.invalid'
            ? catalog.future
            : http.Response('{}', 404),
      );
      await tester.runAsync(
        () => http.runWithClient(() async {
          await StremioService.instance.getCatalogAddons();
          await tester.pumpWidget(
            const MaterialApp(home: SearchScreen(isTelevision: false)),
          );
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }, () => client),
      );
      await tester.pump();

      final pill = find.byType(AnimatedPositioned);
      final closed = tester.getRect(pill);
      await tester.tap(find.byIcon(Icons.search_rounded));
      await tester.pump();
      expect(tester.getRect(pill), closed);
      final field = find.byType(EditableText);
      final fieldWidth = tester.getSize(field).width;
      expect(tester.widget<EditableText>(field).focusNode.hasFocus, isFalse);

      await tester.pump(const Duration(milliseconds: 150));
      final halfway = tester.getRect(pill);
      expect(halfway.left, lessThan(closed.left));
      expect(halfway.width, greaterThan(closed.width));
      expect(tester.getSize(field).width, fieldWidth);
      expect(tester.widget<EditableText>(field).focusNode.hasFocus, isFalse);

      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump(const Duration(milliseconds: 16));
      final opened = tester.getRect(pill);
      expect(halfway.left, greaterThan(opened.left));
      expect(halfway.width, lessThan(opened.width));
      expect(tester.getSize(field).width, fieldWidth);
      expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);

      await tester.tap(find.byTooltip('Hide search'));
      await tester.pump();
      expect(tester.getRect(pill), opened);
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.getRect(pill).left, greaterThan(opened.left));
      expect(tester.getRect(pill).left, lessThan(closed.left));
      await tester.pump(const Duration(milliseconds: 150));
      expect(tester.getRect(pill), closed);
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() async {
        catalog.complete(http.Response('{"metas":[]}', 200));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
    });
  }
}
