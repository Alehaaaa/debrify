import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/sources_notice.dart';
import '../../widgets/detail/download_choice_sheet.dart';
import '../../utils/filter_ladder.dart';
import '../saved_source_filters.dart';
import 'download_outcome.dart';
import 'download_preferences.dart';
import 'download_request.dart';

/// The Download button, start to finish. Every detail page goes through
/// here, so the button asks the same thing and behaves the same way
/// everywhere:
///
/// 1. with "Always ask" on, a sheet asks how (and for a series how much);
///    otherwise the remembered [DownloadPreferences] answer;
/// 2. automatic: [auto] downloads the best source matching the saved
///    filters;
/// 3. manual — or automatic that found nothing — [openSources] shows the
///    source list in download mode, with a note saying why when automatic
///    came back empty.
abstract final class DownloadCoordinator {
  static Future<void> start(
    BuildContext context, {
    required DownloadRequest request,
    required bool isTelevision,
    VoidCallback? onViewDownloads,
    required Future<DownloadOutcome> Function(DownloadScope? scope) auto,
    required FutureOr<void> Function(
      DownloadScope? scope,
      SourcesNotice? notice,
    )
    openSources,
  }) async {
    var prefs = await DownloadPreferences.load();
    if (prefs.alwaysAsk) {
      final filters = await SavedSourceFilters.load();
      if (!context.mounted) return;
      final answer = await showDownloadChoiceSheet(
        context,
        request: request,
        isTelevision: isTelevision,
        filterSummary: FilterLadder(filters).filterSummary(),
        initial: prefs,
        onViewDownloads: onViewDownloads,
      );
      if (answer == null) return;
      prefs = answer;
      await prefs.save();
    }
    if (!context.mounted) return;
    final scope = request.isSeries ? prefs.seriesScope : null;
    SourcesNotice? notice;
    if (prefs.choice == DownloadChoice.auto) {
      final outcome = await auto(scope);
      if (outcome.done || !context.mounted) return;
      notice = outcome.notice;
    }
    await openSources(scope, notice);
  }
}
