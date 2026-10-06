import '../models/metadata_preferences.dart';
import '../models/stremio_addon.dart';
import 'imdb_trailer_service.dart';
import 'metadata_preferences_service.dart';
import 'metadata_provider_service.dart';
import 'stremio_service.dart';
import 'youtube_service.dart';

/// Playable trailer streams for a catalog title, for the app's small ambient
/// players (a Spotlight card's preview, a Reel).
///
/// The trailer comes from whichever provider the user's metadata preferences
/// pick for trailers (the title's own YouTube id when the catalog carries one,
/// else its full details), resolved at [maxHeight]; when that fails and the
/// preferences allow a fallback, IMDb's own trailer MP4 stands in. Null when
/// nothing playable turns up, or when [isCurrent] says the caller stopped
/// caring part-way (profile switch, widget gone).
Future<YoutubeResolvedStreams?> resolveTitleTrailer(
  StremioMeta item, {
  required bool Function() isCurrent,
  int maxHeight = 480,
}) async {
  final prefs = await MetadataPreferencesService.loadForBackground(
    isCurrent: isCurrent,
  );
  if (prefs == null || !isCurrent()) return null;
  final imdb = item.effectiveImdbId;
  final candidates = await MetadataProviderService.instance.trailers(
    item,
    () async {
      if ((item.trailerYtId ?? '').isNotEmpty) return item.trailerYtId;
      if (imdb == null || !isCurrent()) return null;
      return (await StremioService.instance.fetchMetaDetails(
        imdbId: imdb,
        type: item.type,
      ))?.trailerYtId;
    },
    preferences: prefs,
  );
  if (!isCurrent()) return null;
  final youtubeId = candidates.firstOrNull?.key;
  var streams = youtubeId == null
      ? null
      : await YoutubeService.resolveStreams(
          youtubeId,
          maxHeightOverride: maxHeight,
          preferVp9: false,
        );
  if (!isCurrent()) return null;
  if ((streams == null || !streams.hasPlayable) &&
      imdb != null &&
      (prefs.provider(MetadataCategory.trailers) ==
              MetadataPreferences.current ||
          prefs.fallback)) {
    streams = await ImdbTrailerService.resolveTrailer(
      imdb,
      maxHeight: maxHeight,
    );
  }
  if (!isCurrent() || streams == null || !streams.hasPlayable) return null;
  return streams;
}
