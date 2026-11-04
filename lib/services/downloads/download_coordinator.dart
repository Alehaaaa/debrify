import 'dart:async';

import 'package:flutter/material.dart';

import '../../models/sources_notice.dart';
import '../../widgets/detail/download_choice_sheet.dart';
import '../../utils/filter_ladder.dart';
import '../saved_source_filters.dart';
import 'download_feedback.dart';
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
/// 3. manual: [openSources] shows the source list in download mode;
///    automatic that found nothing says why and offers that list (with the
///    explanation on top) instead of opening it unasked.
abstract final class DownloadCoordinator {
  /// The Download button HELD: straight to the source list in download mode,
  /// whatever "Always ask" and automatic say. A series covers the remembered
  /// episode range from where Play would start.
  static Future<void> chooseSource({
    required DownloadRequest request,
    required FutureOr<void> Function(
      DownloadScope? scope,
      SourcesNotice? notice,
    )
    openSources,
  }) async {
    final prefs = await DownloadPreferences.load();
    await openSources(request.isSeries ? prefs.seriesScope : null, null);
  }

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
    if (prefs.choice == DownloadChoice.manual) {
      await openSources(scope, null);
      return;
    }
    // Automatic runs in the background; when it comes back empty the user
    // is told why and offered the list — never pulled into it mid-browse.
    final outcome = await auto(scope);
    final notice = outcome.notice;
    if (outcome.done || notice == null || !context.mounted) return;
    DownloadFeedback.offer(
      context,
      notice.title,
      actionLabel: 'Choose source',
      onAction: () => openSources(scope, notice),
    );
  }
}
