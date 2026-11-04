import 'package:debrify/services/playback_restart_ticket.dart';
import 'package:debrify/widgets/detail/detail_resume_choice.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatResumeTimestamp', () {
    test('reads like a player clock', () {
      expect(formatResumeTimestamp(21 * 60000 + 44000), '21:44');
      expect(formatResumeTimestamp(65000), '1:05');
      expect(formatResumeTimestamp(3600000 + 5 * 60000 + 12000), '1:05:12');
      expect(formatResumeTimestamp(-5), '0:00');
    });
  });

  group('resumeTimestampFrom', () {
    test('offers a real in-progress position', () {
      expect(
        resumeTimestampFrom({'positionMs': 1304000, 'durationMs': 6000000}),
        1304000,
      );
    });
    test('ignores stray taps, finished titles and missing records', () {
      expect(resumeTimestampFrom(null), isNull);
      expect(resumeTimestampFrom({'positionMs': 3000}), isNull);
      expect(
        resumeTimestampFrom({'positionMs': 5800000, 'durationMs': 6000000}),
        isNull,
      );
    });
  });

  group('PlaybackRestartTicket', () {
    tearDown(PlaybackRestartTicket.clear);

    test('a movie ticket is spent by its first matching launch', () {
      PlaybackRestartTicket.request('tt1', aliases: ['cinemeta:tt1']);
      expect(PlaybackRestartTicket.matches('tt2'), isFalse);
      expect(PlaybackRestartTicket.take('cinemeta:tt1'), isTrue);
      expect(PlaybackRestartTicket.take('tt1'), isFalse);
    });

    test('an episode ticket covers only its own episode', () {
      PlaybackRestartTicket.request('tt9', season: 2, episode: 3);
      expect(PlaybackRestartTicket.take('tt9', season: 2, episode: 4), isFalse);
      expect(PlaybackRestartTicket.take('tt9', season: 2, episode: 3), isTrue);
    });
  });
}
