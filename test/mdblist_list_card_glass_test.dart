import 'package:debrify/services/mdblist/mdblist_list_source.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/theme/glass_chrome.dart';
import 'package:debrify/theme/premium_looks.dart';
import 'package:debrify/widgets/see_all/mdblist_list_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(AppTheme app, {bool focused = false}) => MaterialApp(
    home: AppThemeScope(
      theme: app,
      child: Scaffold(
        body: Center(
          child: SizedBox(
            width: 145,
            height: 220,
            child: MdblistListCard(
              list: const MdblistListChoice(id: 12, name: 'Saved picks'),
              focused: focused,
              onTap: () {},
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('Discover list cards share frosted fills and focus edges', (
    tester,
  ) async {
    final glass = PremiumLooks.glass.build();
    await tester.pumpWidget(host(glass));
    var card = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    var decoration = card.decoration! as BoxDecoration;
    expect(decoration.color, GlassChrome.fill(glass));
    expect(decoration.gradient, isNull);
    expect(decoration.border!.top.color, GlassChrome.edge(glass));

    await tester.pumpWidget(host(glass, focused: true));
    card = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    decoration = card.decoration! as BoxDecoration;
    expect(decoration.color, GlassChrome.fill(glass, raised: true));
    expect(decoration.border!.top.color, GlassChrome.edge(glass, active: true));

    await tester.pumpWidget(host(AppThemes.legacy));
    card = tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
    decoration = card.decoration! as BoxDecoration;
    expect(decoration.gradient, isA<LinearGradient>());
  });
}
