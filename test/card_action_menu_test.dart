import 'package:background_downloader/background_downloader.dart';
import 'package:debrify/models/downloaded_media.dart';
import 'package:debrify/models/stremio_addon.dart';
import 'package:debrify/screens/downloads_screen.dart';
import 'package:debrify/services/downloaded_media_service.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/widgets/card_action_menu.dart';
import 'package:debrify/widgets/catalog_item_tile.dart';
import 'package:debrify/widgets/hold_feedback.dart';
import 'package:debrify/widgets/see_all/see_all_poster_grid.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(
  home: AppThemeScope(
    theme: AppThemes.legacy,
    child: Scaffold(body: child),
  ),
);

Future<void> _rightClick(WidgetTester tester, Finder finder) => tester.tap(
  finder,
  kind: PointerDeviceKind.mouse,
  buttons: kSecondaryMouseButton,
);

void main() {
  const movie = StremioMeta(id: 'tt1', type: 'movie', name: 'Some Movie');

  testWidgets('menu lists its rows and returns the picked value', (
    tester,
  ) async {
    String? picked;
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              picked = await showCardActionMenu<String>(
                context,
                title: 'Some Movie',
                subtitle: 'Movie',
                isTelevision: false,
                actions: const [
                  CardMenuAction(
                    value: 'play',
                    icon: Icons.play_arrow_rounded,
                    label: 'Play',
                    description: 'Start it.',
                  ),
                  CardMenuAction(
                    value: 'delete',
                    icon: Icons.delete_outline_rounded,
                    label: 'Delete',
                    description: 'Gone.',
                    destructive: true,
                  ),
                ],
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('Some Movie'), findsOneWidget);
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(picked, 'delete');
    expect(find.text('Play'), findsNothing);
  });

  group('SeeAllPosterGrid', () {
    Widget grid({void Function(StremioMeta)? onQuickPlay}) => SeeAllPosterGrid(
      items: const [movie],
      isTelevision: false,
      loadingMore: false,
      exhausted: true,
      onLoadMore: () {},
      onOpen: (_) {},
      onQuickPlay: onQuickPlay,
    );

    testWidgets('without a menu, hold keeps Quick Play', (tester) async {
      var played = 0;
      await tester.pumpWidget(_host(grid(onQuickPlay: (_) => played++)));
      await tester.longPress(find.byType(CatalogItemTile));
      expect(played, 1);
      expect(
        tester
            .widget<CatalogItemTile>(find.byType(CatalogItemTile))
            .onSecondaryTap,
        isNull,
      );
    });

    testWidgets('a library scope takes over hold and right-click', (
      tester,
    ) async {
      var played = 0;
      final calls = <({bool click, bool canPlay})>[];
      await tester.pumpWidget(
        _host(
          CardOptionsScope(
            onOptions: (item, {required open, quickPlay}) {
              calls.add((
                click: CardMenuGesture.isSecondaryClick,
                canPlay: quickPlay != null,
              ));
            },
            child: grid(onQuickPlay: (_) => played++),
          ),
        ),
      );
      await tester.longPress(find.byType(CatalogItemTile));
      await _rightClick(tester, find.byType(CatalogItemTile));
      expect(played, 0);
      expect(calls, [
        (click: false, canPlay: true),
        (click: true, canPlay: true),
      ]);
      // The flag only lives for the click's own dispatch.
      expect(CardMenuGesture.isSecondaryClick, isFalse);
    });
  });

  testWidgets('Downloads poster menu steers a running download', (
    tester,
  ) async {
    final active = LocalDownload(
      TaskRecord(
        DownloadTask(
          taskId: 'active',
          url: 'https://example.com/video',
          filename: 'Movie.mp4',
        ),
        TaskStatus.running,
        .4,
        1024,
      ),
      const DownloadedMedia(
        id: 'tt123',
        title: 'Downloading Movie',
        type: 'movie',
      ),
      '',
    );
    await tester.pumpWidget(
      _host(DownloadsScreen(loadDownloads: () async => [active])),
    );
    await tester.pumpAndSettle();

    await _rightClick(tester, find.byType(CatalogItemTile));
    await tester.pumpAndSettle();
    // Nothing finished, so nothing to play — but it can be paused or deleted.
    expect(find.text('Play'), findsNothing);
    expect(find.text('Open download'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Resume'), findsNothing);
    expect(find.text('Delete download'), findsOneWidget);

    await tester.tap(find.text('Delete download'));
    await tester.pumpAndSettle();
    expect(find.text('Delete download?'), findsOneWidget);
    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(find.text('Delete download?'), findsNothing);
  });

  group('HoldFeedback', () {
    final ctl = HoldFeedbackController();
    Widget host() => _host(
      Center(
        child: HoldFeedback(
          controller: ctl,
          child: GestureDetector(
            onLongPress: () {},
            child: const SizedBox(width: 120, height: 180),
          ),
        ),
      ),
    );
    // The frosted lens is real backdrop blur.
    Finder ripple() => find.descendant(
      of: find.byType(HoldFeedback),
      matching: find.byType(BackdropFilter),
    );

    bool sunk(WidgetTester tester) => tester
        .widgetList<Transform>(
          find.descendant(
            of: find.byType(HoldFeedback),
            matching: find.byType(Transform),
          ),
        )
        .any((t) => t.transform.storage[0] < 1); // x scale

    testWidgets('a plain tap never shows the glass', (tester) async {
      await tester.pumpWidget(host());
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(HoldFeedback)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(ripple(), findsNothing);
      expect(sunk(tester), isFalse);
      await gesture.up();
      // Nothing on the way out either — no flood, no thaw.
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 50));
        expect(ripple(), findsNothing);
        expect(sunk(tester), isFalse);
      }
    });

    testWidgets('a held press frosts the tile and thaws after', (tester) async {
      await tester.pumpWidget(host());
      expect(ripple(), findsNothing);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(HoldFeedback)),
      );
      await tester.pump(const Duration(milliseconds: 200)); // past the grace
      await tester.pump(const Duration(milliseconds: 100));
      expect(ripple(), findsOneWidget);
      expect(sunk(tester), isTrue);
      // A pointer press never draws the TV ring.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(ripple(), findsNothing);
      expect(sunk(tester), isFalse);
    });

    testWidgets('scrolling away lets the glass go', (tester) async {
      await tester.pumpWidget(host());
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(HoldFeedback)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 100));
      expect(ripple(), findsOneWidget);
      await gesture.moveBy(const Offset(0, 40));
      await tester.pumpAndSettle();
      expect(ripple(), findsNothing);
      await gesture.up();
    });

    testWidgets('a TV hold fills the ring through the controller', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      ctl.start(const Duration(milliseconds: 600));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      ctl.cancel();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });
  });

  testWidgets('Fix match lists only movies and shows and returns the pick', (
    tester,
  ) async {
    StremioMeta? picked;
    String? searched;
    await tester.pumpWidget(
      _host(
        Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              picked = await showFixMatchDialog(
                context,
                initialQuery: 'Some Movie',
                search: (query) async {
                  searched = query;
                  return const [
                    StremioMeta(id: 'tt1', type: 'movie', name: 'Some Movie'),
                    StremioMeta(id: 'ch1', type: 'tv', name: 'Some Channel'),
                  ];
                },
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(searched, 'Some Movie');
    expect(find.text('Some Channel'), findsNothing);
    await tester.tap(find.widgetWithText(ListTile, 'Some Movie'));
    await tester.pumpAndSettle();
    expect(picked?.id, 'tt1');
  });

  group('HoldableTile', () {
    Widget host({required VoidCallback onTap, VoidCallback? onHold}) => _host(
      Center(
        child: HoldableTile(
          onTap: onTap,
          onHold: onHold,
          child: SizedBox(
            width: 100,
            height: 150,
            child: Material(child: InkWell(autofocus: true, onTap: onTap)),
          ),
        ),
      ),
    );

    testWidgets('tap opens, hold and right-click open the menu', (
      tester,
    ) async {
      var taps = 0, holds = 0;
      await tester.pumpWidget(host(onTap: () => taps++, onHold: () => holds++));
      await tester.tap(find.byType(InkWell));
      await tester.pumpAndSettle();
      expect((taps, holds), (1, 0));
      await tester.longPress(find.byType(InkWell));
      await tester.pumpAndSettle();
      expect((taps, holds), (1, 1));
      await _rightClick(tester, find.byType(InkWell));
      await tester.pumpAndSettle();
      expect((taps, holds), (1, 2));
    });

    testWidgets('a held OK opens the menu; a short OK opens the tile', (
      tester,
    ) async {
      var taps = 0, holds = 0;
      await tester.pumpWidget(host(onTap: () => taps++, onHold: () => holds++));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect((taps, holds), (1, 0));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
      await tester.pump(const Duration(milliseconds: 600));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
      await tester.pumpAndSettle();
      expect((taps, holds), (1, 1));
    });

    testWidgets('without a menu it is the plain tile', (tester) async {
      var taps = 0;
      await tester.pumpWidget(host(onTap: () => taps++));
      expect(find.byType(HoldFeedback), findsNothing);
      await tester.tap(find.byType(InkWell));
      expect(taps, 1);
    });
  });
}
