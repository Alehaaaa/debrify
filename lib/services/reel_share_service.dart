import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/platform_util.dart';
import 'reels_feed.dart';

/// Only public metadata and the official YouTube clip leave the app. Resolved
/// playback URLs can expire and must never be used as share links.
class ReelShareContent {
  ReelShareContent.fromReel(ReelTitle reel)
    : title = reel.item.name.trim(),
      clipName = reel.clipName.trim(),
      url = Uri.https('youtu.be', '/${reel.clipKey}');

  final String title;
  final String clipName;
  final Uri url;

  String get caption => [
    if (title.isNotEmpty) title,
    if (clipName.isNotEmpty && clipName != title) clipName,
  ].join(' — ');

  String get text => [if (caption.isNotEmpty) caption, '$url'].join('\n');
}

typedef ReelNativeShare =
    Future<bool> Function(ReelShareContent content, Rect? origin);

class ReelShareService {
  const ReelShareService({ReelNativeShare? nativeShare})
    : _nativeShare = nativeShare;

  final ReelNativeShare? _nativeShare;
  static const _channel = MethodChannel('debrify/reel_share');

  /// Opens the system share UI, or a copy/open sheet on unsupported platforms.
  /// [origin] is the share button's rectangle in Flutter view coordinates.
  Future<void> share(
    BuildContext context,
    ReelTitle reel, {
    Rect? origin,
  }) async {
    final content = ReelShareContent.fromReel(reel);
    try {
      if (await (_nativeShare ?? _shareNative)(content, origin)) return;
    } catch (_) {
      // Missing OS sharing support should leave a useful, local fallback.
    }
    if (!context.mounted) return;
    final copied = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: const Color(0xFF17191D),
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (_) => _ReelShareSheet(content: content),
    );
    if (copied == true && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Clip link copied')),
      );
    }
  }

  static Future<bool> _shareNative(
    ReelShareContent content,
    Rect? origin,
  ) async {
    if (kIsWeb) return false;
    if (Platform.isAndroid) {
      await AndroidIntent(
        action: 'android.intent.action.SEND',
        type: 'text/plain',
        arguments: {
          'android.intent.extra.TEXT': content.text,
          'android.intent.extra.SUBJECT': content.title,
          'android.intent.extra.TITLE': content.title,
        },
      ).launchChooser('Share clip');
      return true;
    }
    if (PlatformUtil.isIosMobile || Platform.isMacOS) {
      return await _channel.invokeMethod<bool>('share', {
            'title': content.title,
            'text': content.caption,
            'url': content.url.toString(),
            if (origin != null)
              'origin': {
                'x': origin.left,
                'y': origin.top,
                'width': origin.width,
                'height': origin.height,
              },
          }) ??
          false;
    }
    return false;
  }
}

class _ReelShareSheet extends StatefulWidget {
  const _ReelShareSheet({required this.content});

  final ReelShareContent content;

  @override
  State<_ReelShareSheet> createState() => _ReelShareSheetState();
}

class _ReelShareSheetState extends State<_ReelShareSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _copy() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await Clipboard.setData(ClipboardData(text: '${widget.content.url}'));
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not copy the link. You can select it above.';
        });
      }
    }
  }

  Future<void> _open() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final opened = await launchUrl(
        widget.content.url,
        mode: LaunchMode.externalApplication,
      );
      if (!opened) throw StateError('No application can open this link');
      if (mounted) Navigator.of(context).pop(false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not open YouTube. Copy the link to share it.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.content;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Share clip',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            content.title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (content.clipName.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              content.clipName,
              style: const TextStyle(color: Colors.white70, height: 1.4),
            ),
          ],
          const SizedBox(height: 18),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: SelectableText(
                '${content.url}',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.icon(
            autofocus: true,
            onPressed: _busy ? null : _copy,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              minimumSize: const Size.fromHeight(50),
            ),
            icon: const Icon(Icons.link_rounded),
            label: const Text('Copy link'),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _busy ? null : _open,
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              minimumSize: const Size.fromHeight(48),
            ),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: const Text('Open in YouTube'),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.white70),
              ),
            ),
        ],
      ),
    );
  }
}
