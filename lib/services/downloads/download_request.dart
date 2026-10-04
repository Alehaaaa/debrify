/// How much of a series a download covers.
enum DownloadScope { episode, nextEpisodes, season }

/// "Next episodes" downloads this many, starting at the one Play would open.
const int kNextEpisodesCount = 3;

/// What the user asked to download: a movie (or any single title), or a
/// series from the episode Play would open — narrowed by a [DownloadScope]
/// once they've said how much.
class DownloadRequest {
  const DownloadRequest.title({required this.id, required this.title})
    : season = null,
      episode = null;

  const DownloadRequest.series({
    required this.id,
    required this.title,
    required int this.season,
    required int this.episode,
  });

  /// Catalog id (IMDb when known) — what downloads are grouped under.
  final String id;
  final String title;
  final int? season;
  final int? episode;

  bool get isSeries => season != null;

  /// The episode to search for, or null to search the season's packs.
  int? searchEpisode(DownloadScope? scope) =>
      scope == DownloadScope.season ? null : episode;

  /// How many episodes from [searchEpisode] on.
  int episodeCount(DownloadScope? scope) =>
      scope == DownloadScope.nextEpisodes ? kNextEpisodesCount : 1;

  /// The episodes to keep from a pack; null keeps all of them.
  Set<int>? wantedEpisodes(DownloadScope? scope) {
    final first = searchEpisode(scope);
    if (!isSeries || first == null) return null;
    return {for (var i = 0; i < episodeCount(scope); i++) first + i};
  }

  /// "Episode 4", "Episodes 4–6", "Season 2".
  String scopeLabel(DownloadScope scope) => switch (scope) {
    DownloadScope.episode => 'Episode $episode',
    DownloadScope.nextEpisodes =>
      'Episodes $episode–${episode! + kNextEpisodesCount - 1}',
    DownloadScope.season => 'Season $season',
  };
}
