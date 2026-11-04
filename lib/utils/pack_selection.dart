import '../models/downloaded_media.dart';

/// One file in a pack, as the download picker sees it.
typedef PackFile = ({String name, int? sizeBytes});

/// Bonus material and samples: never what someone pressing Download wants.
final RegExp _extra = RegExp(
  r'(^|[^a-z])(sample|trailer|teaser|featurettes?|extras?|bonus|'
  r'behind[ ._-]?the[ ._-]?scenes|deleted[ ._-]?scenes|interviews?|bloopers?)'
  r'([^a-z]|$)',
  caseSensitive: false,
);

bool isPackExtra(String name) => _extra.hasMatch(name);

/// Which files of a pack to tick by default: real episodes that aren't on the
/// device yet and, when [wanted] is given, only those episodes (of [season],
/// when known). Files that name no episode count as wanted unless a specific
/// set was asked for, so a movie or an oddly named pack still downloads.
Set<int> defaultPackSelection(
  List<PackFile> files, {
  Set<({int season, int episode})> onDevice = const {},
  Set<int>? wanted,
  int? season,
  String? packName,
}) {
  final picked = <int>{};
  for (var i = 0; i < files.length; i++) {
    final file = files[i];
    if (isPackExtra(file.name)) continue;
    final at = detectDownloadedEpisode(file.name, packName: packName);
    if (at.season != null &&
        at.episode != null &&
        onDevice.contains((season: at.season!, episode: at.episode!))) {
      continue;
    }
    if (wanted != null) {
      if (at.episode == null || !wanted.contains(at.episode)) continue;
      if (season != null && at.season != null && at.season != season) {
        continue;
      }
    }
    picked.add(i);
  }
  return picked;
}
