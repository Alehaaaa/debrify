import 'package:flutter/material.dart';

import '../../theme/app_theme_scope.dart';
import '../../theme/app_motion.dart' show kMenuSheetAnimation;
import '../../utils/tv_keys.dart';

/// What a held Continue button can do instead of its tap.
enum DetailResumeChoice { resume, restart, sources }

/// `21:44`, or `1:05:12` past the hour — the clock a player would show.
String formatResumeTimestamp(int positionMs) {
  final total = Duration(milliseconds: positionMs < 0 ? 0 : positionMs);
  final h = total.inHours;
  final m = total.inMinutes.remainder(60);
  final s = total.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:${m.toString().padLeft(2, '0')}:$s' : '$m:$s';
}

/// Below this a saved position is a stray tap, not a place to come back to.
const int kMinResumeTimestampMs = 5000;

/// The playback position worth offering from a saved resume record
/// (`positionMs`/`durationMs`), or null when there is nothing to continue:
/// no record, a few seconds in, or effectively finished.
int? resumeTimestampFrom(Map<String, dynamic>? state) {
  if (state == null) return null;
  final position = (state['positionMs'] as num?)?.toInt() ?? 0;
  final duration = (state['durationMs'] as num?)?.toInt() ?? 0;
  if (position < kMinResumeTimestampMs) return null;
  if (duration > 0 && position >= duration * 0.95) return null;
  return position;
}

/// Asks whether to continue from [positionMs] or start over, after the user
/// holds the detail page's Continue button. [canChooseSource] keeps the
/// hold's older job — the manual source list — one row away.
///
/// Wrapped in [TvHeldKeyGuard]: a remote hold opens it while OK is still
/// down, and the first key repeat must not activate the autofocused row.
Future<DetailResumeChoice?> showDetailResumeChoiceSheet(
  BuildContext context, {
  required String title,
  required int positionMs,
  required bool isTelevision,
  String? episodeLabel,
  bool canChooseSource = false,
}) {
  final app = AppThemeScope.of(context);
  final stamp = formatResumeTimestamp(positionMs);
  final subject = episodeLabel == null ? title : '$title · $episodeLabel';
  return showModalBottomSheet<DetailResumeChoice>(
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
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 2, 20, 10),
                child: Text(
                  subject,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: app.core.tx,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
              _ResumeChoiceRow(
                autofocus: isTelevision,
                icon: Icons.play_arrow_rounded,
                label: 'Continue from $stamp',
                description: 'Pick up where you left off.',
                onTap: () =>
                    Navigator.of(sheetContext).pop(DetailResumeChoice.resume),
              ),
              _ResumeChoiceRow(
                icon: Icons.replay_rounded,
                label: 'Start from beginning',
                description:
                    'Play from 0:00. Your saved progress is kept until you '
                    'watch past it.',
                onTap: () =>
                    Navigator.of(sheetContext).pop(DetailResumeChoice.restart),
              ),
              if (canChooseSource)
                _ResumeChoiceRow(
                  icon: Icons.video_library_rounded,
                  label: 'Choose source',
                  description: 'Browse sources instead of playing now.',
                  onTap: () => Navigator.of(
                    sheetContext,
                  ).pop(DetailResumeChoice.sources),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    ),
  );
}

class _ResumeChoiceRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;
  final VoidCallback onTap;
  final bool autofocus;

  const _ResumeChoiceRow({
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
