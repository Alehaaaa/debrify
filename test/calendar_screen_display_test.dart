import 'dart:convert';
import 'package:debrify/widgets/trakt_calendar_day_sheet.dart';
import 'package:debrify/utils/platform_util.dart';
import 'package:debrify/services/secret_vault.dart';
import 'package:debrify/screens/trakt_calendar_screen.dart';
import 'package:debrify/services/profiles/profile_preferences.dart';
import 'package:debrify/services/profiles/profile_runtime.dart';
import 'package:debrify/services/storage_service.dart';
import 'package:debrify/services/trakt/trakt_calendar_service.dart';
import 'package:debrify/widgets/calendar_display_preferences.dart';
import 'package:debrify/theme/app_theme_scope.dart';
import 'package:debrify/theme/glass_chrome.dart';
import 'package:debrify/theme/premium_looks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  for (final layout in [
    (name: 'desktop', size: const Size(1200, 900), tv: false, glass: false),
    (name: 'phone', size: const Size(390, 844), tv: false, glass: false),
    (name: 'TV', size: const Size(1280, 720), tv: true, glass: false),
    (name: 'phone glass', size: const Size(390, 844), tv: false, glass: true),
    (name: 'TV glass', size: const Size(1280, 720), tv: true, glass: true),
  ]) {
    testWidgets(
      '${layout.name}: today-first calendar with saved time format and sheet',
      (tester) async {
        SecretVault.debugReset(deviceIdOverride: 'calendar-test');
        SharedPreferences.setMockInitialValues({});
        ProfileRuntime.debugReset();
        ProfileRuntime.initializeLegacy();
        TraktCalendarService.instance.invalidate();
        addTearDown(() {
          ProfileRuntime.debugReset();
          TraktCalendarService.instance.invalidate();
        });
        await tester.runAsync(
          () => StorageService.setTraktSession(
            accessToken: 'test',
            refreshToken: 'test',
            expiryMs: 9000000000000,
          ),
        );
        PlatformUtil.debugSetTvOS(layout.tv);
        addTearDown(() => PlatformUtil.debugSetTvOS(null));
        tester.view
          ..physicalSize = layout.size
          ..devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        // Phone keeps its options in icon buttons; desktop and TV show them
        // as labelled fields beside the list.
        final compact = layout.size.width < 600;
        final frosted = layout.glass ? PremiumLooks.glass.build() : null;
        Widget host() => frosted == null
            ? const MaterialApp(home: TraktCalendarScreen())
            : AppThemeScope(
                theme: frosted,
                child: const MaterialApp(home: TraktCalendarScreen()),
              );
        final now = DateTime.now();
        Map<String, Object> entry(int day, String title, [int? traktId]) => {
          'first_aired': DateTime(
            now.year,
            now.month,
            day,
            17,
            5,
          ).toUtc().toIso8601String(),
          'episode': {'season': 1, 'number': 1},
          'show': {
            'title': title,
            'ids': <String, Object>{'trakt': traktId ?? day},
          },
        };
        final client = MockClient(
          (_) async => http.Response(
            jsonEncode([
              if (now.day > 1) entry(now.day - 1, 'Earlier episode'),
              entry(now.day, 'Today episode'),
              entry(now.day, 'Another episode', 1001),
              entry(now.day, 'Third episode', 1002),
              entry(now.day, 'Fourth episode', 1003),
            ]),
            200,
          ),
        );
        await http.runWithClient(() async {
          await tester.runAsync(() async {
            await tester.pumpWidget(host());
            await Future<void>.delayed(const Duration(milliseconds: 100));
          });
          await tester.pumpAndSettle();
          expect(find.text('Today episode'), findsOneWidget);
          expect(find.text('Earlier episode'), findsNothing);
          final calendarScaffold = tester.widget<Scaffold>(
            find.byType(Scaffold),
          );
          final calendarGround =
              (calendarScaffold.body! as Container).decoration!
                  as BoxDecoration;
          if (frosted != null) {
            expect(calendarScaffold.backgroundColor, frosted.core.pane);
            expect(calendarGround.color, GlassChrome.fill(frosted));
            expect(calendarGround.gradient, isNull);
          } else {
            expect(calendarGround.gradient, isA<LinearGradient>());
          }
          if (layout.tv) {
            final header = tester.widget<Container>(
              find
                  .ancestor(
                    of: find.text(
                      'Browse only the days that have episodes airing.',
                    ),
                    matching: find.byType(Container),
                  )
                  .first,
            );
            final decoration = header.decoration! as BoxDecoration;
            if (frosted != null) {
              expect(decoration.color, GlassChrome.fill(frosted, raised: true));
              expect(decoration.gradient, isNull);
              expect(decoration.border!.top.color, GlassChrome.edge(frosted));
            } else {
              expect(decoration.gradient, isNotNull);
            }
          }
          if (frosted != null && layout.tv) {
            // The TV card used to paint an almost-opaque gradient and a white
            // inactive border even when the surrounding Calendar was glass.
            expect(
              tester
                  .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
                  .any(
                    (card) =>
                        card.decoration is BoxDecoration &&
                        (card.decoration! as BoxDecoration).color ==
                            GlassChrome.fill(frosted),
                  ),
              isTrue,
            );
          }
          if (frosted != null && compact) {
            final popup = tester.widget<PopupMenuButton<CalendarTimeFormat>>(
              find.byType(PopupMenuButton<CalendarTimeFormat>),
            );
            expect(popup.color, GlassChrome.fill(frosted, raised: true));
            expect(popup.shape, GlassChrome.shape(frosted, radius: 14));
          }
          await tester.tap(
            compact
                ? find.byTooltip('Time format')
                : find.byType(DropdownButtonFormField<CalendarTimeFormat>),
          );
          await tester.pumpAndSettle();
          await tester.tap(
            compact
                ? find.ancestor(
                    of: find.text('12-hour').last,
                    matching: find.byType(
                      CheckedPopupMenuItem<CalendarTimeFormat>,
                    ),
                  )
                : find.text('12-hour').last,
          );
          await tester.pumpAndSettle();
          expect(find.text('5:05 PM'), findsWidgets);
          expect(
            (await ProfilePreferences.instance()).getString(
              'calendar_time_format',
            ),
            'twelveHour',
          );
          // Desktop/phone episode rows open the series detail directly. The
          // day sheet is reached via the remaining-episodes row; on TV the
          // focused day card opens the day sheet with OK.
          final dayTrigger = layout.tv
              ? find.text('Today episode')
              : find.text('1 more episode');
          await tester.ensureVisible(dayTrigger);
          await tester.pumpAndSettle();
          await tester.tap(dayTrigger);
          await tester.pumpAndSettle();
          expect(find.byType(TraktCalendarDaySheet), findsOneWidget);
          if (frosted != null) {
            final row = tester.widget<InkWell>(
              find
                  .descendant(
                    of: find.byType(TraktCalendarDaySheet),
                    matching: find.byType(InkWell),
                  )
                  .first,
            );
            expect(row.hoverColor, GlassChrome.fill(frosted, raised: true));
            expect(row.focusColor, GlassChrome.fill(frosted, raised: true));
          }
          expect(
            find.descendant(
              of: find.byType(TraktCalendarDaySheet),
              matching: find.textContaining('5:05 PM'),
            ),
            findsWidgets,
          );
          Navigator.of(tester.element(find.text('Today episode').last)).pop();
          await tester.pumpAndSettle();
          await tester.tap(
            compact
                ? find.byTooltip('Show earlier days')
                : find.text('Show earlier days'),
          );
          await tester.pumpAndSettle();
          if (now.day > 1) expect(find.text('Earlier episode'), findsOneWidget);
          if (compact) {
            expect(find.byTooltip('From today'), findsOneWidget);
          } else if (layout.tv) {
            expect(find.text('From today'), findsOneWidget);
          } else {
            expect(
              tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
              isTrue,
            );
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.runAsync(() async {
            await tester.pumpWidget(host());
            await Future<void>.delayed(const Duration(milliseconds: 100));
          });
          await tester.pumpAndSettle();
          expect(find.text('5:05 PM'), findsWidgets);
          expect(find.text('Earlier episode'), findsNothing);
          await tester.pumpWidget(const SizedBox.shrink());
        }, () => client);
      },
    );
  }
}
