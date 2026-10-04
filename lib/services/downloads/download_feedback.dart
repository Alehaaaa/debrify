import 'dart:async';

import 'package:flutter/material.dart';

import '../../screens/downloads_screen.dart' show DownloadedTitleScreen;
import '../downloaded_media_service.dart';
import '../main_page_bridge.dart';

/// Every download message the user sees, in one voice: a started download
/// always offers View, and failures always say what to do next.
abstract final class DownloadFeedback {
  static void started(BuildContext context, {String? titleId, int files = 1}) {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          files > 1 ? 'Downloading $files episodes.' : 'Download started.',
        ),
        duration: const Duration(seconds: 5),
        action: SnackBarAction(
          label: 'View',
          onPressed: () => unawaited(openTitle(navigator.context, titleId)),
        ),
      ),
    );
  }

  static void failed(
    BuildContext context, [
    String message = 'Could not start the download. Try another source.',
  ]) => info(context, message);

  static void info(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
      );
  }

  /// A title's download page when it has downloads, else the Downloads tab.
  static Future<void> openTitle(BuildContext context, String? titleId) async {
    if (titleId != null && titleId.isNotEmpty) {
      try {
        final all = await DownloadedMediaService.load(includeTransfers: true);
        final items = all.where((e) => e.media?.id == titleId).toList();
        if (items.isNotEmpty && context.mounted) {
          await Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => DownloadedTitleScreen(items: items),
            ),
          );
          return;
        }
      } catch (_) {}
    }
    MainPageBridge.switchTab?.call(MainTab.downloads);
  }
}
