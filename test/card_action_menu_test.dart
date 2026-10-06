import 'package:background_downloader/background_downloader.dart';
import 'package:debrify/models/downloaded_media.dart';
import 'package:debrify/models/stremio_addon.dart';
import 'package:debrify/screens/downloads_screen.dart';
import 'package:debrify/services/downloaded_media_service.dart';
import 'package:debrify/theme/app_theme.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/widgets/card_action_menu.dart';
import 'package:debrify/widgets/catalog_item_tile.dart';
import 'package:debrify/widgets/see_all/see_all_poster_grid.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
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
}
