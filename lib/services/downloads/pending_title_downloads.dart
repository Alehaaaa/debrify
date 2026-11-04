import 'package:flutter/foundation.dart';

/// Where an automatic download stands BEFORE it has a file to fetch.
///
/// The Download button's automatic path ([TorrentDownloads.downloadBest])
/// spends seconds — sometimes much longer — finding and preparing a source
/// before any download task exists. Without this the title was invisible on
/// the Downloads page for that whole stretch; now it shows as its poster with
/// the phase on top, in the same radial style the progress sweep uses.
enum PendingDownloadPhase {
  /// Searching the title's sources.
  searching('Searching sources'),

  /// Probing the candidates that matched the saved filters.
  checking('Checking sources'),

  /// Handing the winner to the debrid service and queueing the file.
  adding('Adding source');

  const PendingDownloadPhase(this.label);
  final String label;
}

/// One title an automatic download is still preparing.
@immutable
class PendingTitleDownload {
  const PendingTitleDownload({
    required this.id,
    required this.title,
    required this.type,
    required this.phase,
    this.poster,
    this.year,
    this.onCancel,
  });

  /// Catalog id — the same key the Downloads grid groups a title's files by.
  final String id;
  final String title;

  /// 'movie' or 'series'.
  final String type;
  final String? poster;
  final String? year;
  final PendingDownloadPhase phase;

  /// Stops the search; null once it can no longer be stopped.
  final VoidCallback? onCancel;

  PendingTitleDownload copyWith({PendingDownloadPhase? phase}) =>
      PendingTitleDownload(
        id: id,
        title: title,
        type: type,
        poster: poster,
        year: year,
        phase: phase ?? this.phase,
        onCancel: onCancel,
      );
}

/// The automatic downloads still preparing a source, by catalog id.
abstract final class PendingTitleDownloads {
  static final ValueNotifier<Map<String, PendingTitleDownload>> entries =
      ValueNotifier(const {});

  /// A token per [begin], so a finished run never clears a newer run's entry
  /// for the same title.
  static final Map<String, Object> _owners = {};

  /// Starts showing [entry]; returns the token [update] and [end] need.
  static Object begin(PendingTitleDownload entry) {
    final token = Object();
    _owners[entry.id] = token;
    entries.value = {...entries.value, entry.id: entry};
    return token;
  }

  static void update(Object token, String id, PendingDownloadPhase phase) {
    if (!identical(_owners[id], token)) return;
    final current = entries.value[id];
    if (current == null || current.phase == phase) return;
    entries.value = {...entries.value, id: current.copyWith(phase: phase)};
  }

  static void end(Object token, String id) {
    if (!identical(_owners[id], token)) return;
    _owners.remove(id);
    final next = {...entries.value}..remove(id);
    entries.value = next;
  }

  @visibleForTesting
  static void resetForTesting() {
    _owners.clear();
    entries.value = const {};
  }
}
