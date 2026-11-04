import 'package:debrify/models/downloaded_media.dart';
import 'package:debrify/services/torrent_playback_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const meta = PlaybackMeta(
    imdbId: 'tt1234567',
    title: 'Example Show',
    contentType: 'series',
    season: 2,
    episode: 1,
  );
  for (final filename in [
    'Example.S02E04.1080p.mkv',
    'Example.2x04.mkv',
    'Example.S02.E04.mkv',
    'Example.Season 2 Episode 4.mkv',
    'Example.S02EP04.mkv',
  ]) {
    test('pack identity comes from $filename', () {
      final media = DownloadedMedia.fromMetadata(
        downloadMediaMetadata(meta, fileName: filename, isPack: true),
      );
      expect(media?.season, 2);
      expect(media?.episode, 4);
      expect(media?.id, 'tt1234567');
    });
  }
  for (final filename in ['E04.mkv', 'Episode 04.mkv', '04 - Title.mkv']) {
    test('season pack provides season for $filename', () {
      expect(
        detectDownloadedEpisode(
          filename,
          packName: 'Example Season 2 Complete',
        ),
        (season: 2, episode: 4),
      );
    });
  }
  test('ambiguous pack file does not inherit the selected episode', () {
    final media = DownloadedMedia.fromMetadata(
      downloadMediaMetadata(
        meta,
        fileName: 'Behind the scenes.mkv',
        isPack: true,
      ),
    );
    expect(media?.season, isNull);
    expect(media?.episode, isNull);
  });
  test('resolution, year and audio channels are not episode identifiers', () {
    for (final name in [
      'Example.2024.1080p.mkv',
      'Example.2160p.5.1.mkv',
      '1080p.mkv',
    ]) {
      expect(detectDownloadedEpisode(name, packName: 'Example S02 Complete'), (
        season: null,
        episode: null,
      ));
    }
  });
  test('single episode can use the explicit media selection', () {
    final media = DownloadedMedia.fromMetadata(
      downloadMediaMetadata(meta, fileName: 'stream.mp4'),
    );
    expect(media?.season, 2);
    expect(media?.episode, 1);
  });
  test(
    'movie metadata does not gain episode coordinates from its filename',
    () {
      const movie = PlaybackMeta(
        imdbId: 'tt2345678',
        title: 'Movie',
        contentType: 'movie',
      );
      final media = DownloadedMedia.fromMetadata(
        downloadMediaMetadata(movie, fileName: 'Movie.S01E02.mkv'),
      );
      expect(media?.type, 'movie');
      expect(media?.season, isNull);
    },
  );
  test('older season pack files group locally without a catalog identity', () {
    final first = DownloadedMedia.fromFilename(
      'Example.S02E01.mkv',
      packName: 'Example.S02.Complete',
    );
    final second = DownloadedMedia.fromFilename(
      'Example.S02E02.mkv',
      packName: 'Example.S02.Complete',
    );
    expect(first?.key, second?.key);
    expect(first?.isCatalogLinked, false);
    expect(second?.episode, 2);
  });
  test('legacy and malformed metadata remain usable as unlinked files', () {
    for (final value in [null, '', '{}', '{bad', '{"media":{"id":12}}']) {
      expect(DownloadedMedia.fromMetadata(value), isNull);
    }
  });
}
