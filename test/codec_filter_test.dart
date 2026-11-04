import 'package:debrify/models/torrent.dart';
import 'package:debrify/models/torrent_filter_state.dart';
import 'package:debrify/services/saved_source_filters.dart';
import 'package:debrify/utils/filter_ladder.dart';
import 'package:debrify/utils/torrent_filter_matcher.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Torrent _t(String name) => Torrent(
  rowid: 0,
  infohash: 'a' * 40,
  name: name,
  sizeBytes: 2 * 1024 * 1024 * 1024,
  createdUnix: 0,
  seeders: 10,
  leechers: 0,
  completed: 0,
  scrapedDate: 0,
);

void main() {
  test('reads the codec off the release name', () {
    expect(
      TorrentFilterMatcher.detectVideoCodec('Movie.2024.1080p.WEB-DL.x265'),
      VideoCodec.hevc,
    );
    expect(
      TorrentFilterMatcher.detectVideoCodec('Movie 2024 2160p H.265 HDR'),
      VideoCodec.hevc,
    );
    expect(
      TorrentFilterMatcher.detectVideoCodec('Movie.2024.1080p.BluRay.x264'),
      VideoCodec.avc,
    );
    expect(
      TorrentFilterMatcher.detectVideoCodec('Movie.2024.1080p.WEB.AV1.Opus'),
      VideoCodec.av1,
    );
    expect(
      TorrentFilterMatcher.detectVideoCodec('Movie.2024.1080p.WEB-DL'),
      isNull,
    );
  });

  test('a codec facet keeps only releases that name that codec', () {
    final torrents = [
      _t('Movie.2024.1080p.WEB-DL.x265'),
      _t('Movie.2024.1080p.WEB-DL.x264'),
      _t('Movie.2024.1080p.WEB-DL.AV1'),
      _t('Movie.2024.1080p.WEB-DL'),
    ];
    final kept = TorrentFilterMatcher.apply(
      torrents,
      TorrentFilterState(codecs: {VideoCodec.av1, VideoCodec.hevc}),
    );
    expect(kept.map((t) => t.name), [
      'Movie.2024.1080p.WEB-DL.x265',
      'Movie.2024.1080p.WEB-DL.AV1',
    ]);
  });

  test('the ladder ranks the chosen codec first but keeps the rest', () {
    final ladder = FilterLadder(TorrentFilterState(codecs: {VideoCodec.avc}));
    final ordered = ladder.order([
      _t('Movie.2024.1080p.WEB-DL.x265'),
      _t('Movie.2024.1080p.WEB-DL.x264'),
    ]);
    expect(ordered.map((t) => t.name), [
      'Movie.2024.1080p.WEB-DL.x264',
      'Movie.2024.1080p.WEB-DL.x265',
    ]);
  });

  test('saved filters round-trip, codec included', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    final filters = TorrentFilterState(
      qualities: {QualityTier.fullHd},
      languages: {AudioLanguage.spanish},
      codecs: {VideoCodec.hevc},
    );
    await SavedSourceFilters.save(filters);
    expect(await SavedSourceFilters.load(), filters);
    expect((await FilterLadder.fromSavedDefaults()).filters, filters);
  });
}
