import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:debrify/services/trakt/trakt_episode_model.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/theme/glass_chrome.dart';
import 'package:debrify/theme/premium_looks.dart';
import 'package:debrify/widgets/detail/detail_episode_cells.dart';
import 'package:debrify/widgets/detail/theme/detail_theme.dart';
import 'package:debrify/widgets/detail/theme/detail_themes.dart';

void main() {
  testWidgets('detail episode focus uses the selected appearance material', (
    tester,
  ) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    final episode = TraktEpisode(season: 1, number: 1, title: 'Episode One');
    Widget host(AppTheme app) => MaterialApp(
      home: AppThemeScope(
        theme: app,
        child: DetailThemeScope(
          theme: DetailThemes.signal,
          child: Scaffold(
            body: DetailEpisodeRow(
              episode: episode,
              fallbackImage: '',
              progress: null,
              isNext: false,
              focusNode: node,
              onPlay: () {},
              onOptions: () {},
            ),
          ),
        ),
      ),
    );
    Color? rowColor() => tester
        .widgetList<Container>(
          find.descendant(
            of: find.byType(DetailEpisodeRow),
            matching: find.byType(Container),
          ),
        )
        .firstWhere((widget) => widget.padding == const EdgeInsets.all(8))
        .decoration
        .letColor();

    final glass = PremiumLooks.glass.build();
    await tester.pumpWidget(host(glass));
    node.requestFocus();
    await tester.pump();
    expect(rowColor(), GlassChrome.fill(glass, raised: true));

    await tester.pumpWidget(host(AppThemes.legacy));
    await tester.pump();
    expect(rowColor(), DetailThemes.signal.panel);
    await tester.pumpWidget(const SizedBox());
  });
}

extension on Decoration? {
  Color? letColor() => switch (this) {
    BoxDecoration(:final color) => color,
    _ => null,
  };
}
