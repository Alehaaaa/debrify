import 'package:flutter/material.dart';

import '../../models/sources_notice.dart';

/// Why an automatic download couldn't pick something.
enum DownloadMiss {
  /// Sources exist, but none match the saved filters.
  noFilterMatch,

  /// Matching sources exist, but none is ready on the debrid service.
  notReady,

  /// The search found nothing at all.
  nothingFound,
}

/// How an automatic download went. When it [missed], [notice] is what the
/// source list says so the user knows why they're picking by hand.
class DownloadOutcome {
  const DownloadOutcome.started() : miss = null, filterSummary = '';
  const DownloadOutcome.missed(
    DownloadMiss this.miss, {
    this.filterSummary = '',
  });

  /// Null when something is downloading (or the user cancelled).
  final DownloadMiss? miss;

  /// The saved filters, readable ("1080p · H.265"); empty when none.
  final String filterSummary;

  bool get done => miss == null;

  SourcesNotice? get notice => switch (miss) {
    null => null,
    DownloadMiss.noFilterMatch => SourcesNotice(
      title: 'No match for your filters',
      message: filterSummary.isEmpty
          ? "Here's everything we found — tap one to download it."
          : "There's no $filterSummary version right now. Here's "
                'everything we found — tap one to download it.',
      icon: Icons.tune_rounded,
      showAll: true,
    ),
    DownloadMiss.notReady => const SourcesNotice(
      title: 'Nothing ready to download instantly',
      message:
          "Pick any source below. If it isn't ready yet, we'll fetch it and "
          'start the download for you.',
      icon: Icons.hourglass_top_rounded,
    ),
    DownloadMiss.nothingFound => const SourcesNotice(
      title: "We couldn't pick one automatically",
      message: 'Choose a source below to download it.',
      showAll: true,
    ),
  };
}
