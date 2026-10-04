import 'package:background_downloader/background_downloader.dart';

import '../../models/downloaded_title_state.dart';
import '../downloaded_media_service.dart';

/// Where one title's downloads stand, read the same way everywhere it shows:
/// the Downloads grid's poster sweep and a detail page's Download button.
class TitleDownloadSummary {
  const TitleDownloadSummary._(this.state, this.progress, this.status);

  static const none = TitleDownloadSummary._(
    DownloadedTitleState.none,
    null,
    null,
  );

  /// [live] holds progress reported since [items] were loaded, by task id.
  factory TitleDownloadSummary.of(
    Iterable<LocalDownload> items, {
    Map<String, double> live = const {},
  }) {
    final all = items.toList();
    if (all.isEmpty) return none;
    final pending = all.where((e) => !e.isReady).toList();
    if (pending.isEmpty) {
      return const TitleDownloadSummary._(
        DownloadedTitleState.downloaded,
        null,
        null,
      );
    }
    final total = all.fold<double>(
      0,
      (sum, e) =>
          sum +
          (e.isReady
              ? 1
              : (live[e.record.taskId] ?? e.record.progress).clamp(0.0, 1.0)),
    );
    final String? status;
    if (pending.any((e) => e.record.status == TaskStatus.running)) {
      status = null;
    } else if (pending.any((e) => e.record.status == TaskStatus.failed)) {
      status = 'Download failed';
    } else if (pending.every((e) => e.record.status == TaskStatus.paused)) {
      status = 'Paused';
    } else {
      status = 'Queued';
    }
    return TitleDownloadSummary._(
      all.any((e) => e.isReady)
          ? DownloadedTitleState.downloaded
          : DownloadedTitleState.downloading,
      total / all.length,
      status,
    );
  }

  final DownloadedTitleState state;

  /// 0..1 while any file is still arriving, else null.
  final double? progress;

  /// "Paused", "Queued", "Download failed" — null while actively downloading.
  final String? status;

  bool get inFlight => progress != null;

  /// The Download button's label: "Downloading 42%" while it runs.
  String get buttonLabel => inFlight
      ? (status ?? 'Downloading ${(progress! * 100).floor()}%')
      : state.label;
}
