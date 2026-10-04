import '../models/torrent_filter_state.dart';
import 'storage_service.dart';

/// The source filters the user last searched with — the same persisted values
/// as Settings → Filter Settings. The Sources list opens with them, writes its
/// changes back, and Quick Play and auto-download rank by them.
class SavedSourceFilters {
  const SavedSourceFilters._();

  static Future<TorrentFilterState> load() async {
    final results = await Future.wait([
      StorageService.getDefaultFilterQualities(),
      StorageService.getDefaultFilterRipSources(),
      StorageService.getDefaultFilterLanguages(),
      StorageService.getDefaultFilterSizes(),
      StorageService.getDefaultFilterDynamicRanges(),
      StorageService.getDefaultFilterCodecs(),
    ]);
    Set<T> parse<T extends Enum>(List<String> names, List<T> values) => {
      for (final name in names) ...values.where((e) => e.name == name),
    };
    return TorrentFilterState(
      qualities: parse(results[0], QualityTier.values),
      ripSources: parse(results[1], RipSourceCategory.values),
      languages: parse(results[2], AudioLanguage.values),
      sizes: parse(results[3], SizeBucket.values),
      dynamicRanges: parse(results[4], DynamicRange.values),
      codecs: parse(results[5], VideoCodec.values),
    );
  }

  static Future<void> save(TorrentFilterState filters) async {
    List<String> names(Iterable<Enum> values) => [
      for (final value in values) value.name,
    ];
    await Future.wait([
      StorageService.setDefaultFilterQualities(names(filters.qualities)),
      StorageService.setDefaultFilterRipSources(names(filters.ripSources)),
      StorageService.setDefaultFilterLanguages(names(filters.languages)),
      StorageService.setDefaultFilterSizes(names(filters.sizes)),
      StorageService.setDefaultFilterDynamicRanges(
        names(filters.dynamicRanges),
      ),
      StorageService.setDefaultFilterCodecs(names(filters.codecs)),
    ]);
  }
}
