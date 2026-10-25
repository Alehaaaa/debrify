import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/media_identity.dart';
import 'continue_watching_sync_service.dart';
import 'profiles/profile_runtime.dart';
import 'profiles/profile_scope.dart';
import 'storage_service.dart';
import 'watchlist_sync_service.dart';

/// An actual movie completion, unlike merely starting playback or navigating
/// into a detail, is the one source-of-truth event for downstream cleanup.
///
/// Local completion is persisted first so Home and later Watchlist reconciliation
/// do not resurrect a movie after a slow or disconnected provider responds.
/// Remote attempts are best effort and do not delay the player's return route.
abstract final class FinishedMovieReconciliationService {
  // Null is the expected key for legacy (non-profile) installations.
  static final Map<ProfileScope?, Map<String, Future<void>>> _inFlight = {};

  static Future<void> recordWatchedMovie(String rawId) {
    final id = MediaIdentity.progressId(rawId, 'movie').trim().toLowerCase();
    if (id.isEmpty) return Future<void>.value();
    final scope = ProfileRuntime.scope.value;
    final items = _inFlight.putIfAbsent(scope, () => {});
    final active = items[id];
    if (active != null) return active;

    final operation = _record(id, scope);
    items[id] = operation;
    // A detached whenComplete future can surface an unhandled asynchronous
    // error if the coordinator ever changes. The original operation remains
    // the only future exposed to callers.
    unawaited(
      operation.then<void>(
        (_) {
          if (identical(items[id], operation)) items.remove(id);
          if (items.isEmpty) _inFlight.remove(scope);
        },
        onError: (Object error, StackTrace stack) {
          if (identical(items[id], operation)) items.remove(id);
          if (items.isEmpty) _inFlight.remove(scope);
        },
      ),
    );
    return operation;
  }

  static Future<void> _record(String id, ProfileScope? scope) async {
    // If the active profile switches, stop before touching another account.
    if (scope != ProfileRuntime.scope.value) return;
    try {
      // Persist the per-provider cleanup intention before the local finished
      // write. This way an explicit re-add racing the last preference write
      // cancels stale remote cleanup instead of being silently overwritten.
      await WatchlistSyncService.queueCompletedMovieRemoval(id);
      if (scope != ProfileRuntime.scope.value) return;
      // Pin local persistence to the profile that actually watched the movie.
      // Otherwise a profile switch while awaiting preferences could mark the
      // newly selected account's watch history instead.
      if (scope != null) {
        await ProfileRuntime.withCapturedScope(
          scope,
          () => StorageService.markMovieAsFinished(id),
        );
      } else {
        await StorageService.markMovieAsFinished(id);
      }
      if (scope != ProfileRuntime.scope.value) return;
      await WatchlistSyncService.removeCompletedMovieLocally(id);
      if (scope != ProfileRuntime.scope.value) return;
      // The local completed marker and resume/CW removal are durable already.
      // Remote providers can take several seconds or be offline, and must not
      // stall the player's end-of-movie navigation or next progress callback.
      unawaited(
        Future.wait<void>([
          WatchlistSyncService.removeCompletedMovieEverywhere(id),
          ContinueWatchingSyncService.removeEverywhere(
            imdbId: id,
            contentType: 'movie',
            force: true,
            remoteOnly: true,
          ),
        ]).catchError((Object e) {
          debugPrint('Deferred movie cleanup: ${e.runtimeType}');
          return <void>[];
        }),
      );
    } catch (error) {
      debugPrint('Movie completion reconciliation: ${error.runtimeType}');
    }
  }
}
