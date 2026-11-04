import 'dart:convert';
import '../services/torrent_playback_service.dart';
import '../utils/series_parser.dart';

/// Catalog identity is stored with the durable task, never inferred from a title.
class DownloadedMedia {
  final String id, title, type;
  final String? poster, year;
  final int? season, episode;
  const DownloadedMedia({
    required this.id,
    required this.title,
    required this.type,
    this.poster,
    this.year,
    this.season,
    this.episode,
  });

  String get key => '$type:$id';
  String get episodeLabel => season != null && episode != null
      ? 'S${season.toString().padLeft(2, '0')} · E${episode.toString().padLeft(2, '0')}'
      : 'Downloaded file';

  /// Older pack downloads can be organized locally without inventing a catalog ID.
  static DownloadedMedia? fromFilename(String fileName, {String? packName}) {
    final coordinates = detectDownloadedEpisode(fileName, packName: packName);
    if (coordinates.season == null || coordinates.episode == null) return null;
    final name = (packName?.isNotEmpty ?? false) ? packName! : fileName;
    final title = name
        .split(
          RegExp(
            r'(?:[ ._-]+)(?:s\d{1,2}|season[ ._-]*\d{1,2}|\d{1,2}x\d)',
            caseSensitive: false,
          ),
        )
        .first
        .replaceAll(RegExp(r'[._]'), ' ')
        .trim();
    if (title.isEmpty || title == fileName) return null;
    return DownloadedMedia(
      id: 'download-file:${title.toLowerCase()}',
      title: title,
      type: 'series',
      season: coordinates.season,
      episode: coordinates.episode,
    );
  }

  bool get isCatalogLinked => !id.startsWith('download-file:');

  static DownloadedMedia? fromMetadata(String? value) {
    try {
      final m = jsonDecode(value ?? '')['media'] as Map;
      if (m['id'] is! String ||
          (m['id'] as String).isEmpty ||
          m['title'] is! String ||
          !['movie', 'series'].contains(m['type'])) {
        return null;
      }
      return DownloadedMedia(
        id: m['id'],
        title: m['title'],
        type: m['type'],
        poster: m['poster'] as String?,
        year: m['year'] as String?,
        season: (m['season'] as num?)?.toInt(),
        episode: (m['episode'] as num?)?.toInt(),
      );
    } catch (_) {
      return null;
    }
  }
}

String? downloadMediaMetadata(
  PlaybackMeta? meta, {
  required String fileName,
  bool isPack = false,
  String? packName,
}) {
  final id = meta?.imdbId ?? meta?.catalogItem?.id;
  if (meta == null ||
      id == null ||
      id.isEmpty ||
      !['movie', 'series'].contains(meta.contentType)) {
    return null;
  }
  final parsed = detectDownloadedEpisode(fileName, packName: packName);
  final series = meta.contentType == 'series';
  return jsonEncode({
    'media': {
      'id': id, 'title': meta.title ?? meta.catalogItem?.name ?? fileName,
      'type': meta.contentType, 'poster': meta.posterUrl, 'year': meta.year,
      // Never stamp every file in a season pack with the selected episode.
      'season': series
          ? (parsed.season ?? (isPack ? null : meta.season))
          : null,
      'episode': series
          ? (parsed.episode ?? (isPack ? null : meta.episode))
          : null,
    },
  });
}

/// Explicit episode tokens are safe for pack files; resolution/year numbers are not.
/// Folder/pack names may supply a season, but never an episode.
({int? season, int? episode}) detectDownloadedEpisode(
  String fileName, {
  String? packName,
}) {
  final name = fileName.replaceAll(RegExp(r'\\'), '/').split('/').last;
  final explicit =
      RegExp(
        r'(?:^|[^a-z0-9])s(\d{1,2})[ ._-]*ep?[ ._-]*(\d{1,3})(?!\d)',
        caseSensitive: false,
      ).firstMatch(name) ??
      RegExp(
        r'(?:^|[^a-z0-9])(\d{1,2})x(\d{1,3})(?!\d)',
        caseSensitive: false,
      ).firstMatch(name) ??
      RegExp(
        r'season[ ._-]*(\d{1,2})[ ._-]*episode[ ._-]*(\d{1,3})(?!\d)',
        caseSensitive: false,
      ).firstMatch(name);
  if (explicit != null) {
    return (
      season: int.parse(explicit.group(1)!),
      episode: int.parse(explicit.group(2)!),
    );
  }
  final parsed = SeriesParser.parseFilenameConservative(name);
  if (parsed.season != null && parsed.episode != null && parsed.isSeries) {
    return (season: parsed.season, episode: parsed.episode);
  }
  final seasonMatch = RegExp(
    r'(?:^|[^a-z0-9])(?:s|season[ ._-]*)(\d{1,2})(?!\d)',
    caseSensitive: false,
  ).firstMatch('$fileName ${packName ?? ''}');
  final episodeMatch =
      RegExp(
        r'(?:^|[^a-z0-9])(?:e|ep|episode)[ ._-]*(\d{1,3})(?!\d)',
        caseSensitive: false,
      ).firstMatch(name) ??
      RegExp(
        r'^(\d{1,3})(?:[ ._-]|\.[a-z]+$)',
        caseSensitive: false,
      ).firstMatch(name);
  if (seasonMatch != null && episodeMatch != null) {
    return (
      season: int.parse(seasonMatch.group(1)!),
      episode: int.parse(episodeMatch.group(1)!),
    );
  }
  return (season: null, episode: null);
}
