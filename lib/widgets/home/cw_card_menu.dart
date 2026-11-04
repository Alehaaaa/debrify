import 'package:flutter/material.dart';

import '../card_action_menu.dart';

/// What [showCwCardMenu] came back with (null = dismissed).
enum CwCardAction { play, remove }

/// The two-row Play / Remove menu for a Continue Watching card, as the IPTV
/// guide uses it. A thin preset over [showCardActionMenu], which owns the
/// chrome and the DPAD story; Home builds its richer CW menu on that directly.
///
/// The copy is passed in rather than derived here: a Continue Watching row can
/// be local, Trakt, Simkl or IPTV, and "remove" means something different in
/// each.
Future<CwCardAction?> showCwCardMenu(
  BuildContext context, {
  required String title,
  required bool isTelevision,
  required String playDescription,
  required String removeDescription,
  String? posterUrl,
  String? subtitle,

  /// False on PikPak-only setups, where the board hides quick-play entirely —
  /// the menu then exists purely to offer the removal.
  bool showPlay = true,
  bool showRemove = true,
  String playLabel = 'Play',
  String removeLabel = 'Remove from Continue Watching',
}) {
  return showCardActionMenu<CwCardAction>(
    context,
    title: title,
    isTelevision: isTelevision,
    posterUrl: posterUrl,
    subtitle: subtitle,
    actions: [
      if (showPlay)
        CardMenuAction(
          value: CwCardAction.play,
          icon: Icons.play_arrow_rounded,
          label: playLabel,
          description: playDescription,
        ),
      if (showRemove)
        CardMenuAction(
          value: CwCardAction.remove,
          icon: Icons.playlist_remove_rounded,
          label: removeLabel,
          description: removeDescription,
          destructive: true,
        ),
    ],
  );
}
