import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:debrify/models/stremio_addon.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/widgets/detail/theme/detail_themes.dart';
import 'package:debrify/widgets/home/spotlight_board.dart';

/// The touch hero follows the finger: both titles share the screen mid-swipe,
/// release snaps to the nearer one, and selection changes only once the snap
/// settles.
StremioMeta _meta(String id, String name) => StremioMeta(
      id: id,
      imdbId: id,
      type: 'series',
      name: name,
      description: 'About $name.',
      genres: const ['Drama'],
      background: 'https://example.invalid/$id.jpg',
    );

final _addon = StremioAddon(
  id: 'a',
  name: 'A',
  manifestUrl: 'https://example.invalid/manifest.json',
  baseUrl: 'https://example.invalid',
  types: const ['series'],
  resources: const ['catalog'],
);

SpotlightShelf _section(String title, List<StremioMeta> items) =>
    SpotlightShelf(
      title: title,
      nodes: [
        for (var i = 0; i < items.length; i++) FocusNode(debugLabel: 'cell$i'),
      ],
      items: [
        for (final m in items)
          SpotlightCard(image: m.poster, title: m.name, onOpen: () {}),
      ],
    );

final _a = _meta('tt1', 'Alpha');
final _b = _meta('tt2', 'Bravo');
final _c = _meta('tt3', 'Charlie');

void main() {
  late FocusNode hero;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    hero = FocusNode(debugLabel: 'hero');
  });

  tearDown(() => hero.dispose());

  void surface(WidgetTester t, Size size) {
    t.view.physicalSize = size;
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
  }

  Future<SpotlightBoardState> pumpBoard(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    Widget? trailer,
    bool trailersEnabled = false,
    void Function(StremioMeta)? onDwell,
    VoidCallback? onTrailerStop,
    ValueChanged<bool>? onTrailerSuspend,
  }) async {
    surface(tester, size);
    final key = GlobalKey<SpotlightBoardState>();
    final shelf = _section('Top', [_a, _b, _c]);
    addTearDown(() {
      for (final node in shelf.nodes) {
        node.dispose();
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        home: AppThemeScope(
          theme: AppTheme.fromDetail(DetailThemes.byId('signal')),
          child: Scaffold(
            body: SpotlightBoard(
              key: key,
              hero: [_a, _b, _c],
              sections: [shelf],
              heroNode: hero,
              heroAddon: _addon,
              onHeroOpen: (_, __) {},
              dpad: false,
              trailer: trailer,
              trailersEnabled: trailersEnabled,
              onDwell: onDwell,
              onTrailerStop: onTrailerStop,
              onTrailerSuspend: onTrailerSuspend,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    return key.currentState!;
  }

  Finder incoming(String id) =>
      find.byKey(ValueKey('spotlight-hero-incoming-$id'));

  Finder art(String id) => find.byWidgetPredicate(
        (w) =>
            w is CachedNetworkImage &&
            w.imageUrl == 'https://example.invalid/$id.jpg',
      );

  /// A slow drag across the hero, a frame per step (no fling velocity).
  Future<TestGesture> dragHero(WidgetTester tester, double dx) async {
    final gesture = await tester.startGesture(const Offset(195, 300));
    const steps = 10;
    for (var i = 0; i < steps; i++) {
      await gesture.moveBy(Offset(dx / steps, 0));
      await tester.pump(const Duration(milliseconds: 50));
    }
    return gesture;
  }

  group('compact (phone) hero', () {
    testWidgets('both titles share the screen mid-swipe; selection waits', (
      tester,
    ) async {
      final board = await pumpBoard(tester);
      expect(incoming('tt2'), findsNothing);

      final gesture = await dragHero(tester, -150);
      // Follows the finger (less the touch slop).
      expect(board.heroSwipeOffset, inInclusiveRange(-150, -100));
      expect(incoming('tt2'), findsOneWidget);
      expect(art('tt1'), findsOneWidget);
      expect(art('tt2'), findsOneWidget, reason: 'incoming art preloaded');
      // The incoming title sits flush against the outgoing one.
      final outgoingLeft = tester.getTopLeft(art('tt1')).dx;
      final incomingLeft = tester.getTopLeft(art('tt2')).dx;
      expect(incomingLeft - outgoingLeft, closeTo(390, 0.5));
      expect(board.currentHeroId, 'tt1', reason: 'nothing selected mid-drag');

      await gesture.up();
      await tester.pumpAndSettle();
    });

    testWidgets('a release past a third snaps to the next title', (
      tester,
    ) async {
      final board = await pumpBoard(tester);
      final gesture = await dragHero(tester, -200);
      await tester.pump(const Duration(milliseconds: 300)); // velocity → 0
      await gesture.up();
      // Mid-snap the selection still has not moved.
      await tester.pump(const Duration(milliseconds: 60));
      expect(board.currentHeroId, 'tt1');
      await tester.pumpAndSettle();

      expect(board.currentHeroId, 'tt2');
      expect(board.heroSwipeOffset, 0);
      expect(incoming('tt2'), findsNothing);
      expect(art('tt2'), findsOneWidget);
      expect(art('tt1'), findsNothing, reason: 'one hero picture at rest');
    });

    testWidgets('landing does not replay the entrance slide', (tester) async {
      final board = await pumpBoard(tester);
      final gesture = await dragHero(tester, -250);
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      // Run the snap to its last frame, then look at the landing frame.
      for (var i = 0; i < 40 && board.currentHeroId == 'tt1'; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(board.currentHeroId, 'tt2');
      final slide = tester.widget<FractionalTranslation>(
        find
            .ancestor(of: art('tt2'), matching: find.byType(FractionalTranslation))
            .first,
      );
      expect(slide.translation, Offset.zero,
          reason: 'the swiped-in title is already in place');
      expect(tester.getTopLeft(art('tt2')).dx, closeTo(0, 0.5));
    });

    testWidgets('a short release returns to the current title', (
      tester,
    ) async {
      final board = await pumpBoard(tester);
      final gesture = await dragHero(tester, -80);
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(board.currentHeroId, 'tt1');
      expect(board.heroSwipeOffset, 0);
      expect(incoming('tt2'), findsNothing);
    });

    testWidgets('dragging right brings the previous title (wrapping)', (
      tester,
    ) async {
      final board = await pumpBoard(tester);
      final gesture = await dragHero(tester, 200);
      expect(incoming('tt3'), findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(board.currentHeroId, 'tt3');
    });

    testWidgets('a quick flick still pages', (tester) async {
      final board = await pumpBoard(tester);
      await tester.fling(find.byType(SpotlightBoard), const Offset(-60, 0), 900);
      await tester.pumpAndSettle();
      expect(board.currentHeroId, 'tt2');
    });

    testWidgets('grabbing a snap mid-flight continues the drag', (
      tester,
    ) async {
      final board = await pumpBoard(tester);
      var gesture = await dragHero(tester, -200);
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final midSnap = board.heroSwipeOffset;
      expect(midSnap, lessThan(-200));

      // Catch it and pull it back.
      gesture = await dragHero(tester, 300);
      expect(board.currentHeroId, 'tt1', reason: 'the interrupted snap never landed');
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(board.currentHeroId, 'tt1');
      expect(board.heroSwipeOffset, 0);
    });
  });

  testWidgets('a tap that catches a snap does not open the title', (
    tester,
  ) async {
    final opened = <String>[];
    surface(tester, const Size(390, 844));
    final shelf = _section('Top', [_a, _b, _c]);
    addTearDown(() {
      for (final node in shelf.nodes) {
        node.dispose();
      }
    });
    await tester.pumpWidget(
      MaterialApp(
        home: AppThemeScope(
          theme: AppTheme.fromDetail(DetailThemes.byId('signal')),
          child: Scaffold(
            body: SpotlightBoard(
              hero: [_a, _b, _c],
              sections: [shelf],
              heroNode: hero,
              heroAddon: _addon,
              onHeroOpen: (m, _) => opened.add(m.id),
              dpad: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));
    final gesture = await dragHero(tester, -200);
    await tester.pump(const Duration(milliseconds: 300));
    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tapAt(const Offset(300, 200));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
    // At rest a tap opens the showcased title as before.
    await tester.tapAt(const Offset(200, 200));
    await tester.pumpAndSettle();
    expect(opened, hasLength(1));
  });

  group('trailer', () {
    testWidgets('a cancelled swipe pauses and resumes the same trailer', (
      tester,
    ) async {
      final suspends = <bool>[];
      var stops = 0;
      final dwelled = <String>[];
      final board = await pumpBoard(
        tester,
        trailer: const SizedBox.expand(key: ValueKey('trailer')),
        trailersEnabled: true,
        onDwell: (m) => dwelled.add(m.id),
        onTrailerStop: () => stops++,
        onTrailerSuspend: suspends.add,
      );
      await tester.pump(const Duration(seconds: 2));
      expect(dwelled, ['tt1'], reason: 'trailer rolling for the first title');

      final gesture = await dragHero(tester, -80);
      expect(suspends, [true], reason: 'paused while the hero moves');
      // The trailer layer exists once, with the outgoing title.
      expect(find.byKey(const ValueKey('trailer')), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(board.currentHeroId, 'tt1');
      expect(suspends, [true, false], reason: 'resumed, not restarted');
      expect(stops, 0);
    });

    testWidgets('a committed swipe stops the old trailer and re-arms', (
      tester,
    ) async {
      final suspends = <bool>[];
      var stops = 0;
      final dwelled = <String>[];
      final board = await pumpBoard(
        tester,
        trailer: const SizedBox.expand(key: ValueKey('trailer')),
        trailersEnabled: true,
        onDwell: (m) => dwelled.add(m.id),
        onTrailerStop: () => stops++,
        onTrailerSuspend: suspends.add,
      );
      await tester.pump(const Duration(seconds: 2));

      final gesture = await dragHero(tester, -250);
      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(board.currentHeroId, 'tt2');
      expect(suspends, [true]);
      expect(stops, 1, reason: 'the outgoing decoder is released');
      await tester.pump(const Duration(seconds: 2));
      expect(dwelled, ['tt1', 'tt2'], reason: 'the landed title gets its own');
    });

    testWidgets('no trailer starts under a moving hero', (tester) async {
      final dwelled = <String>[];
      await pumpBoard(
        tester,
        trailersEnabled: true,
        onDwell: (m) => dwelled.add(m.id),
      );
      // Hold a drag across the moment the cadence would have fired.
      final gesture = await dragHero(tester, -60);
      await tester.pump(const Duration(seconds: 3));
      expect(dwelled, isEmpty);
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 2));
      expect(dwelled, ['tt1'], reason: 're-armed after the cancelled swipe');
    });
  });

  group('wide (tablet) hero', () {
    testWidgets('art and identity slide; focus and dots stay singletons', (
      tester,
    ) async {
      final board = await pumpBoard(tester, size: const Size(1180, 820));
      final heroFocus = find.byWidgetPredicate(
        (w) => w is Focus && w.focusNode == hero,
      );
      expect(heroFocus, findsOneWidget);

      final gesture = await tester.startGesture(const Offset(590, 300));
      for (var i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(-50, 0));
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(art('tt1'), findsOneWidget);
      expect(art('tt2'), findsOneWidget);
      expect(find.text('About Alpha.'), findsOneWidget);
      expect(find.text('About Bravo.'), findsOneWidget,
          reason: 'the synopsis hands over with the drag');
      expect(heroFocus, findsOneWidget, reason: 'never duplicated');
      expect(find.byKey(const ValueKey('spotlight-hero-dots')), findsOneWidget);
      expect(board.currentHeroId, 'tt1');

      await tester.pump(const Duration(milliseconds: 300));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(board.currentHeroId, 'tt2');
      expect(find.text('About Bravo.'), findsOneWidget);
      expect(find.text('About Alpha.'), findsNothing);
      expect(heroFocus, findsOneWidget);
    });
  });
}
