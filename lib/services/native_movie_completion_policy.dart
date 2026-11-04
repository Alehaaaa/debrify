/// Whether an Android TV catalog movie has reached an independently verified
/// watched threshold. A native player can emit `completed` after a renderer
/// error or an aborted stream; an end flag without valid duration/position is
/// not evidence that a movie was watched.
bool isNativeCatalogMovieComplete({
  required int positionMs,
  required int durationMs,
  required int thresholdPercent,
  required bool completed,
}) {
  if (durationMs <= 0 || positionMs <= 0) return false;
  if (thresholdPercent < 1 || thresholdPercent > 100) return false;
  final progress = positionMs.clamp(0, durationMs) * 100.0 / durationMs;
  if (thresholdPercent == 100) {
    // A completed frame may be shy of exact duration because a file's final
    // video packet precedes the container duration. Require a genuine native
    // end notification and a tightly bounded final-frame tolerance.
    return completed && progress >= 90 && durationMs - positionMs <= 1500;
  }
  if (progress >= thresholdPercent) return true;
  // A 90% native signal arriving with a stale/rewound playback position is
  // not enough evidence for destructive remote watchlist reconciliation.
  // Native sends the position again at or above the threshold on later pings.
  return false;
}
