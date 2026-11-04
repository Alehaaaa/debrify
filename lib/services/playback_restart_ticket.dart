/// One-shot "start this from the beginning" request.
///
/// The detail page's long-press "Restart" must open the same title/episode at
/// 0:00 without wiping any saved progress or tracker history — the user may
/// back out after a few seconds and still expect their place to be there.
/// Every launch path (stream, downloaded file, native Android TV player)
/// resolves resume deep inside its own loader, so rather than threading a flag
/// through each of them the page files a ticket here and the resume readers
/// honour it once.
///
/// A ticket is keyed by content identity (IMDb id + season/episode) and
/// expires quickly, so a launch that never happens cannot leak a "start at 0"
/// into a later, unrelated play.
class PlaybackRestartTicket {
  PlaybackRestartTicket._();

  static const _ttl = Duration(minutes: 2);

  static Set<String> _ids = const {};
  static int? _season;
  static int? _episode;
  static DateTime? _at;

  /// The next launch of [imdbId] (and, for a series, S[season]E[episode])
  /// starts at 0:00 instead of its saved position.
  ///
  /// [aliases] covers the same title under the other ids a launch path may
  /// carry it by (a catalog id vs its IMDb id, a downloaded file's media id).
  static void request(
    String imdbId, {
    int? season,
    int? episode,
    Iterable<String?> aliases = const [],
  }) {
    _ids = {
      imdbId.trim(),
      for (final alias in aliases)
        if (alias != null && alias.trim().isNotEmpty) alias.trim(),
    };
    _season = season;
    _episode = episode;
    _at = DateTime.now();
  }

  /// Whether a live ticket covers this content. Does not spend it.
  static bool matches(String? imdbId, {int? season, int? episode}) {
    final at = _at;
    if (_ids.isEmpty || at == null || imdbId == null) return false;
    if (DateTime.now().difference(at) > _ttl) {
      clear();
      return false;
    }
    if (!_ids.contains(imdbId.trim())) return false;
    // A movie ticket has no coordinates; an episode ticket only covers its
    // own episode (auto-advance into the next one resumes normally).
    if (_season == null || _episode == null) return true;
    return season == _season && episode == _episode;
  }

  /// [matches], spending the ticket when it does.
  static bool take(String? imdbId, {int? season, int? episode}) {
    if (!matches(imdbId, season: season, episode: episode)) return false;
    clear();
    return true;
  }

  static void clear() {
    _ids = const {};
    _season = null;
    _episode = null;
    _at = null;
  }
}
