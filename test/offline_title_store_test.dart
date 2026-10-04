import 'dart:io';

import 'package:debrify/models/downloaded_media.dart';
import 'package:debrify/services/imdb_enrichment_service.dart';
import 'package:debrify/services/imdb_parents_guide_service.dart';
import 'package:debrify/services/offline_title_store.dart';
import 'package:debrify/models/stremio_addon.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  final store = OfflineTitleStore.instance;

  const movie = DownloadedMedia(id: 'tt0111161', title: 'A', type: 'movie');

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('offline_titles');
    OfflineTitleStore.debugReset();
    OfflineTitleStore.debugDirectory = () async => dir;
    OfflineTitleStore.debugSkipWarm = true;
  });

  tearDown(() async {
    OfflineTitleStore.debugReset();
    OfflineTitleStore.debugDirectory = null;
    OfflineTitleStore.debugSkipWarm = false;
    await dir.delete(recursive: true);
  });

  test('only downloaded titles are saved, and survive a restart', () async {
    await store.write(movie.id, OfflineTitleStore.meta, {'name': 'x'});
    expect(await store.read(movie.id, OfflineTitleStore.meta), isNull);

    await store.updatePinned([movie]);
    expect(store.isPinned(movie.id), isTrue);
    await store.write(movie.id, OfflineTitleStore.meta, {'name': 'x'});

    OfflineTitleStore.debugReset();
    await store.ensureLoaded();
    expect(store.isPinned(movie.id), isTrue);
    expect(await store.read(movie.id, OfflineTitleStore.meta), {'name': 'x'});
  });

  test('unlinked files are never pinned', () async {
    await store.updatePinned([
      const DownloadedMedia(
        id: 'download-file:show',
        title: 'Show',
        type: 'series',
      ),
    ]);
    expect(store.isPinned('download-file:show'), isFalse);
  });

  test('a removed download keeps its copy for now but is unpinned', () async {
    await store.updatePinned([movie]);
    await store.write(movie.id, OfflineTitleStore.meta, {'name': 'x'});
    await store.updatePinned(const []);
    expect(store.isPinned(movie.id), isFalse);
    expect(await store.read(movie.id, OfflineTitleStore.meta), {'name': 'x'});
  });

  test('page snapshot round-trips everything the page shows', () {
    const snapshot = PageSnapshot(
      meta: StremioMeta(
        id: 'tt0111161',
        type: 'movie',
        name: 'A',
        poster: 'https://img/p.jpg',
        logo: 'https://img/l.png',
      ),
      details: ImdbEnrichment(
        plot: 'Plot',
        rating: 9.3,
        cast: [CastMember(name: 'Actor', imageUrl: 'https://img/c.jpg')],
        didYouKnow: [DidYouKnowEntry(kind: 'Trivia', text: 'Fact')],
        triviaTotal: 3,
        universe: [
          UniverseTitle(imdbId: 'tt1', name: 'B', relation: 'Followed by'),
        ],
      ),
      parentsGuide: ParentsGuideResult(
        categories: [
          ParentsGuideCategory(
            id: 'NUDITY',
            label: 'Sex & Nudity',
            severity: 'Mild',
            severityVotes: 5,
            totalVotes: 9,
            items: [ParentsGuideItem(text: 'Kiss', isSpoiler: true)],
          ),
        ],
      ),
      recommendations: [StremioMeta(id: 'tmdb:1', type: 'movie', name: 'C')],
    );
    final back = PageSnapshot.fromJson(snapshot.toJson())!;
    expect(back.meta!.logo, 'https://img/l.png');
    expect(back.details!.plot, 'Plot');
    expect(back.details!.rating, 9.3);
    expect(back.details!.cast.single.imageUrl, 'https://img/c.jpg');
    expect(back.details!.didYouKnow.single.text, 'Fact');
    expect(back.details!.triviaTotal, 3);
    expect(back.details!.universe.single.relation, 'Followed by');
    expect(back.parentsGuide!.categories.single.items.single.isSpoiler, isTrue);
    expect(back.recommendations.single.name, 'C');
    expect(
      back.imageUrls,
      containsAll([
        'https://img/p.jpg',
        'https://img/l.png',
        'https://img/c.jpg',
      ]),
    );
  });

  test('episode stills are saved under both requested sizes', () {
    expect(
      OfflineTitleStore.episodeImageUrls(
        'https://episodes.metahub.space/tt1/1/1/w780.jpg',
      ),
      [
        'https://episodes.metahub.space/tt1/1/1/w780.jpg',
        'https://episodes.metahub.space/tt1/1/1/w300.jpg',
      ],
    );
  });
}
