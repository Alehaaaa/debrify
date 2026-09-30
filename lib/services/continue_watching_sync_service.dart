import 'simkl/simkl_service.dart';
import 'storage_service.dart';
import 'trakt/trakt_continue_watching_service.dart';
import 'trakt/trakt_service.dart';

/// Removes a title from every Continue Watching owner when unified tracking is
/// enabled. Each remote operation is best-effort so one disconnected account
/// never prevents the other owners from being cleaned up.
class ContinueWatchingSyncService {
  const ContinueWatchingSyncService._();

  static Future<bool> enabled() => StorageService.getSyncAllContinueWatching();

  static Future<void> removeEverywhere({
    required String imdbId,
    required String contentType,
  }) async {
    if (!await enabled()) return;
    final type = contentType == 'series' ? 'series' : 'movie';
    await Future.wait([
      StorageService.removeContinueWatchingItem(imdbId),
      StorageService.clearPlaybackStateByImdbId(imdbId),
      _removeTrakt(imdbId, type),
      _removeSimkl(imdbId, type),
    ]);
  }

  static Future<void> _removeTrakt(String imdbId, String contentType) async {
    if (!await TraktService.instance.isAuthenticated()) return;
    try {
      final service = TraktContinueWatchingService.instance;
      final lists = await Future.wait([
        service.fetchMoviesOrNull(),
        service.fetchShowsOrNull(),
      ]);
      final item = [...?lists[0], ...?lists[1]]
          .cast<TraktContinueWatchingItem?>()
          .firstWhere((item) => item?.id == imdbId, orElse: () => null);
      if (item != null) {
        await service.removeItem(item);
      } else {
        await TraktService.instance.removeFromHistory(imdbId, contentType);
      }
    } catch (_) {}
  }

  static Future<void> _removeSimkl(String imdbId, String type) async {
    if (!await SimklService.instance.isAuthenticated()) return;
    try {
      await Future.wait([
        SimklService.instance.deletePlaybackForImdb(imdbId, contentType: type),
        SimklService.instance.removeFromList(imdbId, type),
      ]);
    } catch (_) {}
  }
}
