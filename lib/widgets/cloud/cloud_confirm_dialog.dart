import 'package:flutter/material.dart';

import '../../theme/app_theme_scope.dart';
import '../../theme/glass_chrome.dart';

/// Shared confirmation surface for Cloud actions. The dialog is a separate
/// overlay, so it needs its own frosted fill and edge (without an extra blur).
class CloudConfirmDialog extends StatelessWidget {
  const CloudConfirmDialog({
    super.key,
    required this.title,
    required this.message,
    required this.confirmLabel,
  });

  final String title;
  final String message;
  final String confirmLabel;

  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    final frosted = GlassChrome.enabled(app);
    return AlertDialog(
      backgroundColor: frosted
          ? GlassChrome.fill(app, raised: true)
          : app.cloud.dialogSurface,
      shape: frosted
          ? GlassChrome.shape(app)
          : RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
      content: Text(
        message,
        style: TextStyle(
          color: frosted ? app.fade(app.core.tx, 0.78) : Colors.grey,
        ),
      ),
      actions: [
        TextButton(
          autofocus: true,
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(
            'Cancel',
            style: TextStyle(color: frosted ? app.core.tx : Colors.grey),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: TextButton.styleFrom(foregroundColor: app.cloud.destructive),
          child: Text(confirmLabel),
        ),
      ],
    );
  }
}
