import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/saved_source_filters.dart';
import '../../services/storage_service.dart';
import '../../services/torrent_playback_service.dart'
    show AutoDownloadMiss, AutoDownloadResult;
import '../../theme/app_motion.dart' show kMenuSheetAnimation;
import '../../theme/app_theme_scope.dart';
import '../../utils/filter_ladder.dart';
import '../../utils/tv_keys.dart';

/// What a title's Download button does: download the best source matching
/// the saved source filters, or open the source list to pick one.
enum DownloadChoice { auto, manual }

/// How much of a series to download.
enum DownloadScope { episode, nextEpisodes, season }

/// "Next episodes" downloads this many, starting at the one Play would open.
const int kNextEpisodesCount = 3;

/// The episode a series' Download button starts from.
typedef DownloadSeriesTarget = ({int season, int episode});

/// Runs a title's Download button. With "Always ask" on (the default) a sheet
/// asks how — and, for a series, how much — to download, and can turn asking
/// off; otherwise the last choices run straight away. Both are also settings
/// (Settings → Downloads).
///
/// When [auto] can't find anything, [manual] runs with its reason so the
/// source list can explain itself instead of the press dead-ending.
Future<void> runDownloadButton(
  BuildContext context, {
  required String title,
  required bool isTelevision,
  DownloadSeriesTarget? series,
  VoidCallback? onViewDownloads,
  required Future<AutoDownloadResult> Function(DownloadScope? scope) auto,
  required FutureOr<void> Function(DownloadScope? scope, AutoDownloadResult? why)
  manual,
}) async {
  final alwaysAsk = await StorageService.getDownloadButtonAlwaysAsk();
  var choice = await StorageService.getDownloadButtonMode() == 'auto'
      ? DownloadChoice.auto
      : DownloadChoice.manual;
  DownloadScope? scope = series == null
      ? null
      : DownloadScope.values.asNameMap()[await StorageService
                .getDownloadSeriesScope()] ??
            DownloadScope.nextEpisodes;
  if (alwaysAsk) {
    if (!context.mounted) return;
    final filters = await SavedSourceFilters.load();
    if (!context.mounted) return;
    final answer = await showDownloadChoiceSheet(
      context,
      title: title,
      isTelevision: isTelevision,
      filterSummary: FilterLadder(filters).filterSummary(),
      series: series,
      initialScope: scope,
      onViewDownloads: onViewDownloads,
    );
    if (answer == null) return;
    choice = answer.choice;
    scope = answer.scope;
    await Future.wait([
      StorageService.setDownloadButtonMode(choice.name),
      StorageService.setDownloadButtonAlwaysAsk(answer.alwaysAsk),
      if (scope != null) StorageService.setDownloadSeriesScope(scope.name),
    ]);
  }
  if (!context.mounted) return;
  AutoDownloadResult? why;
  if (choice == DownloadChoice.auto) {
    why = await auto(scope);
    if (why.done || !context.mounted) return;
  }
  await manual(scope, why);
}

/// Copy for a [DownloadScope], e.g. "Episodes 4–6".
String downloadScopeLabel(DownloadScope scope, DownloadSeriesTarget target) =>
    switch (scope) {
      DownloadScope.episode => 'Episode ${target.episode}',
      DownloadScope.nextEpisodes =>
        'Episodes ${target.episode}–${target.episode + kNextEpisodesCount - 1}',
      DownloadScope.season => 'Season ${target.season}',
    };

/// The source list's note for an automatic download that came back empty.
({String title, String message, IconData icon, bool showAll}) downloadMissNote(
  AutoDownloadResult why,
) => switch (why.miss) {
  AutoDownloadMiss.noFilterMatch => (
    title: 'No match for your filters',
    message: why.filterSummary.isEmpty
        ? "Here's everything we found — tap one to download it."
        : "There's no ${why.filterSummary} version right now. Here's "
              'everything we found — tap one to download it.',
    icon: Icons.tune_rounded,
    showAll: true,
  ),
  AutoDownloadMiss.notReady => (
    title: 'Nothing ready to download instantly',
    message:
        "Pick any source below. If it isn't ready yet, we'll fetch it and "
        'start the download for you.',
    icon: Icons.hourglass_top_rounded,
    showAll: false,
  ),
  _ => (
    title: "We couldn't pick one automatically",
    message: 'Choose a source below to download it.',
    icon: Icons.lightbulb_outline_rounded,
    showAll: true,
  ),
};

/// The how-to-download sheet. Returns null when dismissed.
Future<({DownloadChoice choice, DownloadScope? scope, bool alwaysAsk})?>
showDownloadChoiceSheet(
  BuildContext context, {
  required String title,
  required bool isTelevision,
  String filterSummary = '',
  DownloadSeriesTarget? series,
  DownloadScope? initialScope,
  VoidCallback? onViewDownloads,
}) {
  final app = AppThemeScope.of(context);
  var alwaysAsk = true;
  var scope = series == null
      ? null
      : (initialScope ?? DownloadScope.nextEpisodes);
  return showModalBottomSheet<
    ({DownloadChoice choice, DownloadScope? scope, bool alwaysAsk})
  >(
    sheetAnimationStyle: kMenuSheetAnimation,
    context: context,
    backgroundColor: app.sheetSurface,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => TvHeldKeyGuard(
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: StatefulBuilder(
            builder: (context, setSheetState) {
              void pick(DownloadChoice choice) => Navigator.of(sheetContext)
                  .pop((choice: choice, scope: scope, alwaysAsk: alwaysAsk));
              return SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 2, 12, 10),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Download',
                                  style: TextStyle(
                                    color: app.core.tx,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -0.2,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: app.fade(app.core.tx, 0.45),
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (onViewDownloads != null)
                            TextButton.icon(
                              onPressed: () {
                                Navigator.of(sheetContext).pop();
                                onViewDownloads();
                              },
                              icon: const Icon(
                                Icons.offline_pin_rounded,
                                size: 18,
                              ),
                              label: const Text('My downloads'),
                            ),
                        ],
                      ),
                    ),
                    if (series != null)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final option in DownloadScope.values)
                              ChoiceChip(
                                label: Text(
                                  downloadScopeLabel(option, series),
                                ),
                                selected: scope == option,
                                onSelected: (_) =>
                                    setSheetState(() => scope = option),
                              ),
                          ],
                        ),
                      ),
                    _ChoiceRow(
                      autofocus: isTelevision,
                      icon: Icons.auto_awesome_rounded,
                      label: 'Download automatically',
                      description: filterSummary.isEmpty
                          ? 'We pick the best available source for you.'
                          : 'We pick the best source that matches your '
                                'filters ($filterSummary).',
                      onTap: () => pick(DownloadChoice.auto),
                    ),
                    _ChoiceRow(
                      icon: Icons.list_rounded,
                      label: 'Choose a source',
                      description: 'See the sources and pick one yourself.',
                      onTap: () => pick(DownloadChoice.manual),
                    ),
                    Divider(height: 17, color: app.fade(app.core.tx, 0.08)),
                    SwitchListTile(
                      value: alwaysAsk,
                      onChanged: (value) =>
                          setSheetState(() => alwaysAsk = value),
                      contentPadding: const EdgeInsets.fromLTRB(20, 0, 14, 0),
                      title: Text(
                        'Always ask',
                        style: TextStyle(
                          color: app.core.tx,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      subtitle: Text(
                        alwaysAsk
                            ? 'Show this every time you download.'
                            : 'Next time, do what you pick now. Change it in '
                                  'Settings → Downloads.',
                        style: TextStyle(
                          color: app.fade(app.core.tx, 0.5),
                          fontSize: 12.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
}

class _ChoiceRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onTap;
  final bool autofocus;

  const _ChoiceRow({
    required this.icon,
    required this.label,
    required this.description,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        autofocus: autofocus,
        focusColor: app.fade(app.core.tx, 0.12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 13, 18, 13),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(icon, color: app.core.tx, size: 24),
              ),
              const SizedBox(width: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: app.core.tx,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      style: TextStyle(
                        color: app.fade(app.core.tx, 0.5),
                        fontSize: 13,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
