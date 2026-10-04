import 'package:debrify/utils/pack_selection.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final files = <PackFile>[
    (name: 'Show.S02E01.1080p.mkv', sizeBytes: 1),
    (name: 'Show.S02E02.1080p.mkv', sizeBytes: 1),
    (name: 'Show.S02E03.1080p.mkv', sizeBytes: 1),
    (name: 'Sample/show.s02e01.sample.mkv', sizeBytes: 1),
    (name: 'Extras/Behind.The.Scenes.mkv', sizeBytes: 1),
  ];

  test('skips extras and episodes already on the device', () {
    expect(
      defaultPackSelection(files, onDevice: {(season: 2, episode: 1)}),
      {1, 2},
    );
  });

  test('keeps only the requested episodes of the season', () {
    expect(defaultPackSelection(files, wanted: {2, 3}, season: 2), {1, 2});
    expect(defaultPackSelection(files, wanted: {2}, season: 3), isEmpty);
  });

  test('a file that names no episode still downloads by default', () {
    expect(
      defaultPackSelection([(name: 'Movie.2024.1080p.mkv', sizeBytes: 1)]),
      {0},
    );
  });
}
