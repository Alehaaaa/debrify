import '../storage_service.dart';
import 'download_request.dart';

/// What a title's Download button does without asking: download the best
/// source matching the saved filters, or open the source list.
enum DownloadChoice { auto, manual }

/// The Download button's remembered answers — the sheet's choices and the
/// Settings → Downloads page are two views of these same values.
class DownloadPreferences {
  const DownloadPreferences({
    this.choice = DownloadChoice.manual,
    this.alwaysAsk = true,
    this.seriesScope = DownloadScope.nextEpisodes,
  });

  final DownloadChoice choice;
  final bool alwaysAsk;
  final DownloadScope seriesScope;

  static Future<DownloadPreferences> load() async {
    final results = await Future.wait<Object>([
      StorageService.getDownloadButtonMode(),
      StorageService.getDownloadButtonAlwaysAsk(),
      StorageService.getDownloadSeriesScope(),
    ]);
    return DownloadPreferences(
      choice: results[0] == 'auto'
          ? DownloadChoice.auto
          : DownloadChoice.manual,
      alwaysAsk: results[1] as bool,
      seriesScope:
          DownloadScope.values.asNameMap()[results[2]] ??
          DownloadScope.nextEpisodes,
    );
  }

  Future<void> save() => Future.wait([
    StorageService.setDownloadButtonMode(choice.name),
    StorageService.setDownloadButtonAlwaysAsk(alwaysAsk),
    StorageService.setDownloadSeriesScope(seriesScope.name),
  ]);

  DownloadPreferences copyWith({
    DownloadChoice? choice,
    bool? alwaysAsk,
    DownloadScope? seriesScope,
  }) => DownloadPreferences(
    choice: choice ?? this.choice,
    alwaysAsk: alwaysAsk ?? this.alwaysAsk,
    seriesScope: seriesScope ?? this.seriesScope,
  );
}
