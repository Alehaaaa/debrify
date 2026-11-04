import 'package:flutter/material.dart';

import '../../services/downloads/download_preferences.dart';
import '../../services/downloads/download_request.dart';
import '../../theme/app_motion.dart' show kMenuSheetAnimation;
import '../../theme/app_theme_scope.dart';
import '../../utils/tv_keys.dart';

/// The Download button's sheet: how much (for a series), how (automatic or
/// pick a source), and whether to keep asking. Returns the answer as the
/// [DownloadPreferences] to use — and remember — or null when dismissed.
/// Pure UI: [DownloadCoordinator] decides when it shows and acts on it.
Future<DownloadPreferences?> showDownloadChoiceSheet(
  BuildContext context, {
  required DownloadRequest request,
  required bool isTelevision,
  String filterSummary = '',
  DownloadPreferences initial = const DownloadPreferences(),
  VoidCallback? onViewDownloads,
}) {
  final app = AppThemeScope.of(context);
  var alwaysAsk = true;
  var scope = initial.seriesScope;
  return showModalBottomSheet<DownloadPreferences>(
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
              void pick(DownloadChoice choice) =>
                  Navigator.of(sheetContext).pop(
                    initial.copyWith(
                      choice: choice,
                      alwaysAsk: alwaysAsk,
                      seriesScope: scope,
                    ),
                  );
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
                                  request.title,
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
                    if (request.isSeries)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final option in DownloadScope.values)
                              ChoiceChip(
                                label: Text(request.scopeLabel(option)),
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
