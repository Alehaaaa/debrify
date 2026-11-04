import 'package:flutter/material.dart';

/// A note shown above a source list, written for people rather than logs.
class SourcesNotice {
  const SourcesNotice({
    required this.title,
    required this.message,
    this.icon = Icons.lightbulb_outline_rounded,
    this.showAll = false,
  });

  final String title;
  final String message;
  final IconData icon;

  /// Open with every source instead of the saved filters (which the note is
  /// about). The saved filters themselves are left alone.
  final bool showAll;
}
