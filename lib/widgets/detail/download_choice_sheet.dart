import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/saved_source_filters.dart';
import '../../services/storage_service.dart';
import '../../theme/app_motion.dart' show kMenuSheetAnimation;
import '../../theme/app_theme_scope.dart';
import '../../utils/filter_ladder.dart';
import '../../utils/tv_keys.dart';

/// What a title's Download button does: download the best source matching
/// the saved source filters, or open the source list to pick one.
enum DownloadChoice { auto, manual }

/// Runs a title's Download button. With "Always ask" on (the default) the
/// user picks auto or manual in a sheet, and can turn asking off from it;
/// otherwise the last choice runs straight away. Both are also settings
/// (Settings → Downloads).
///
/// [auto] returns false when it found nothing to download; the source list
/// opens then so the press never dead-ends.
Future<void> runDownloadButton(
  BuildContext context, {
  required String title,
  required bool isTelevision,
  required Future<bool> Function() auto,
  required FutureOr<void> Function() manual,
}) async {
  final alwaysAsk = await StorageService.getDownloadButtonAlwaysAsk();
  var choice = await StorageService.getDownloadButtonMode() == 'auto'
      ? DownloadChoice.auto
      : DownloadChoice.manual;
  if (alwaysAsk) {
    if (!context.mounted) return;
    final filters = await SavedSourceFilters.load();
    if (!context.mounted) return;
    final answer = await showDownloadChoiceSheet(
      context,
      title: title,
      isTelevision: isTelevision,
      filterSummary: FilterLadder(filters).filterSummary(),
    );
    if (answer == null) return;
    choice = answer.choice;
    await Future.wait([
      StorageService.setDownloadButtonMode(choice.name),
      StorageService.setDownloadButtonAlwaysAsk(answer.alwaysAsk),
    ]);
  }
  if (!context.mounted) return;
  if (choice == DownloadChoice.auto) {
    if (await auto()) return;
    if (!context.mounted) return;
  }
  await manual();
}

/// The auto-or-manual sheet. Returns null when dismissed.
Future<({DownloadChoice choice, bool alwaysAsk})?> showDownloadChoiceSheet(
  BuildContext context, {
  required String title,
  required bool isTelevision,
  String filterSummary = '',
}) {
  final app = AppThemeScope.of(context);
  var alwaysAsk = true;
  return showModalBottomSheet<({DownloadChoice choice, bool alwaysAsk})>(
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
              void pick(DownloadChoice choice) => Navigator.of(
                sheetContext,
              ).pop((choice: choice, alwaysAsk: alwaysAsk));
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 2, 20, 10),
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
                  _ChoiceRow(
                    autofocus: isTelevision,
                    icon: Icons.auto_awesome_rounded,
                    label: 'Download automatically',
                    description: filterSummary.isEmpty
                        ? 'The best available source. Set filters in a '
                              'source search to narrow it down.'
                        : 'The best source matching your saved filters: '
                              '$filterSummary.',
                    onTap: () => pick(DownloadChoice.auto),
                  ),
                  _ChoiceRow(
                    icon: Icons.list_rounded,
                    label: 'Choose a source',
                    description: 'Browse the sources and pick one yourself.',
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
