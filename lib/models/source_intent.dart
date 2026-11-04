/// Why the user is looking at a title's sources — the one fact that decides
/// what tapping a source does.
enum SourceIntent {
  /// No intent expressed (the Sources button, an episode long-press): a tap
  /// runs the user's post-torrent action, which may ask Play / Download.
  browse,

  /// Reached from Play: a tap plays.
  play,

  /// Reached from Download: a tap downloads.
  download,
}
