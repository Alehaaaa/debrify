import 'package:debrify/models/stremio_addon.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/theme/glass_chrome.dart';
import 'package:debrify/theme/premium_looks.dart';
import 'package:debrify/widgets/home/spotlight_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final appearance in ['glass', 'classic']) {
    testWidgets('Home compact Play pill in $appearance opens the current title', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final heroNode = FocusNode();
      final cardNode = FocusNode();
      addTearDown(heroNode.dispose);
      addTearDown(cardNode.dispose);
      const item = StremioMeta(
        id: 'tt1',
        imdbId: 'tt1',
        type: 'movie',
        name: 'Movie',
      );
      final addon = StremioAddon(
        id: 'addon',
        name: 'Addon',
        manifestUrl: 'https://unused.test/manifest.json',
        baseUrl: 'https://unused.test',
        types: const ['movie'],
        resources: const ['catalog'],
      );
      final app = appearance == 'glass'
          ? PremiumLooks.glass.build()
          : AppThemes.legacy;
      StremioMeta? opened;
      await tester.pumpWidget(MaterialApp(
        home: AppThemeScope(
          theme: app,
          child: Scaffold(
            body: SpotlightBoard(
              hero: const [item],
              sections: [
                SpotlightShelf(
                  title: 'Top',
                  nodes: [cardNode],
                  items: [
                    SpotlightCard(title: 'Movie', onOpen: () {}),
                  ],
                ),
              ],
              heroNode: heroNode,
              heroAddon: addon,
              onHeroOpen: (meta, _) => opened = meta,
              dpad: false,
              animationsEnabled: false,
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      final play = find.text('Play');
      expect(play, findsOneWidget);
      final ink = tester.widget<Ink>(
        find.ancestor(of: play, matching: find.byType(Ink)).first,
      );
      if (appearance == 'glass') {
        expect(
          ink.decoration,
          GlassChrome.decoration(
            app,
            raised: true,
            radius: BorderRadius.circular(21),
          ),
        );
      } else {
        expect((ink.decoration as BoxDecoration).color, Colors.white);
      }
      expect(find.ancestor(of: play, matching: find.byType(InkWell)), findsOneWidget);
      await tester.tap(play);
      expect(opened?.id, 'tt1');
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
