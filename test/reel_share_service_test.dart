import 'package:debrify/models/stremio_addon.dart';
import 'package:debrify/services/reel_share_service.dart';
import 'package:debrify/services/reels_feed.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const _reel = ReelTitle(
  item: StremioMeta(id: 'tt1234', type: 'movie', name: 'The Movie'),
  clipKey: 'official123',
  clipName: 'The opening scene',
);

void main() {
  test('sharing uses the public clip link and title', () {
    final content = ReelShareContent.fromReel(_reel);
    expect(content.url.toString(), 'https://youtu.be/official123');
    expect(content.text, contains('The Movie'));
    expect(content.text, contains('The opening scene'));
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
            expect(content.url.toString(), 'https://youtu.be/official123');
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
    'unavailable native sharing falls back to copying the public link',
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
      expect(copied, 'https://youtu.be/official123');
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text('Clip link copied'), findsOneWidget);
    },
  );
}
