import 'package:debrify/models/stremio_addon.dart';
import 'package:debrify/services/reel_share_service.dart';
import 'package:debrify/services/reels_feed.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/theme/glass_chrome.dart';
import 'package:debrify/theme/premium_looks.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _reel = ReelTitle(
  item: StremioMeta(id: 'tt1234', type: 'movie', name: 'The Movie'),
  clipKey: 'official123',
  clipName: 'The opening scene',
);

void main() {
  test('sharing links to the title on IMDb instead of the scene clip', () {
    final content = ReelShareContent.fromReel(_reel);
    expect(content.url.toString(), 'https://www.imdb.com/title/tt1234/');
    expect(content.text, contains('The Movie'));
    expect(content.text, isNot(contains('official123')));
    expect(content.text, isNot(contains('The opening scene')));
  });
  test('resolved IMDb field wins over a native catalog ID for a series', () {
    const nativeId = ReelTitle(
      item: StremioMeta(
        id: 'tmdb:1399',
        imdbId: 'tt9876543',
        type: 'series',
        name: 'A Series',
      ),
      clipKey: 'clip9876543',
      clipName: 'Episode scene',
    );
    final content = ReelShareContent.fromReel(nativeId);
    expect(content.url.toString(), 'https://www.imdb.com/title/tt9876543/');
    expect(content.text, isNot(contains('tmdb:1399')));
    expect(content.text, isNot(contains('clip9876543')));
  });

  test('titles without a valid IMDb id share an IMDb title search', () {
    const withoutImdb = ReelTitle(
      item: StremioMeta(id: 'catalog-1234', type: 'movie', name: 'Unknown'),
      clipKey: 'backupClip123',
      clipName: 'A scene',
    );
    final content = ReelShareContent.fromReel(withoutImdb);
    expect(content.url.host, 'www.imdb.com');
    expect(content.url.path, '/find/');
    expect(content.url.queryParameters['q'], 'Unknown');
    expect(content.url.queryParameters['ttype'], 'ft');
    expect(content.text, isNot(contains('backupClip123')));
    expect(content.isImdb, isTrue);
  });

  test('series without an IMDb id search for television titles', () {
    const series = ReelTitle(
      item: StremioMeta(id: 'series-42', type: 'series', name: 'The Show'),
      clipKey: 'clip456',
      clipName: 'Scene',
    );
    final content = ReelShareContent.fromReel(series);
    expect(content.url.queryParameters['ttype'], 'tv');
    expect(content.url.queryParameters['q'], 'The Show');
  });

  Widget host(ReelShareService service) => MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => service.share(context, _reel),
          child: const Text('Share'),
        ),
      ),
    ),
  );

  testWidgets('native dismissal does not open another share sheet', (
    tester,
  ) async {
    var shares = 0;
    await tester.pumpWidget(
      host(
        ReelShareService(
          nativeShare: (content, origin) async {
            shares++;
            expect(
              content.url.toString(),
              'https://www.imdb.com/title/tt1234/',
            );
            return true;
          },
        ),
      ),
    );
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    expect(shares, 1);
    expect(find.byType(BottomSheet), findsNothing);
  });

  testWidgets(
    'unavailable native sharing falls back to copying the IMDb link',
    (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        host(
          ReelShareService(
            nativeShare: (_, _) async => throw MissingPluginException(),
          ),
        ),
      );
      await tester.tap(find.text('Share'));
      await tester.pumpAndSettle();
      expect(find.text('The Movie'), findsOneWidget);
      await tester.tap(find.text('Copy link'));
      await tester.pumpAndSettle();
      expect(copied, 'https://www.imdb.com/title/tt1234/');
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Link copied'), findsOneWidget);
    },
  );
  testWidgets('Reels share controls adopt Frosted Glass when reopened', (
    tester,
  ) async {
    final service = ReelShareService(nativeShare: (_, _) async => false);

    Widget themedHost(bool frosted) => MaterialApp(
      builder: (context, child) => AppThemeScope(
        theme: frosted
            ? PremiumLooks.glass.build()
            : PremiumLooks.field.build(),
        child: child!,
      ),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => service.share(context, _reel),
            child: const Text('Share'),
          ),
        ),
      ),
    );

    await tester.pumpWidget(themedHost(false));
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    FilledButton copyButton() => tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Copy link'),
    );
    expect(copyButton().style?.backgroundColor?.resolve({}), Colors.white);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    await tester.pumpWidget(themedHost(true));
    await tester.tap(find.text('Share'));
    await tester.pumpAndSettle();
    final app = PremiumLooks.glass.build();
    expect(
      copyButton().style?.backgroundColor?.resolve({}),
      GlassChrome.fill(app, raised: true),
    );
    expect(
      copyButton().style?.shape?.resolve({}),
      GlassChrome.shape(app, active: true),
    );
    expect(
      tester.widget<Text>(find.text('Share title')).style?.color,
      app.core.tx,
    );
    expect(
      tester.widget<SelectableText>(find.byType(SelectableText)).style?.color,
      app.core.tx,
    );
    expect(find.text('Open in IMDb'), findsOneWidget);
  });
}
