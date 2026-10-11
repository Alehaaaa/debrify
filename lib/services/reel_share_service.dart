import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/platform_util.dart';
import '../theme/app_theme_scope.dart';
import '../theme/glass_chrome.dart';
import '../theme/widgets/glass_surface.dart';
import 'reels_feed.dart';

/// Share the media's permanent IMDb page rather than its incidental scene clip.
/// A title without an IMDb id links to an IMDb title search for that movie/show.
class ReelShareContent {
  ReelShareContent.fromReel(ReelTitle reel)
    : title = reel.item.name.trim(),
      url =
          _imdbUrl(reel.item.effectiveImdbId) ??
          _imdbUrl(reel.item.id) ??
          Uri.https('www.imdb.com', '/find/', {
            'q': reel.item.name.trim(),
            's': 'tt',
            'ttype': reel.item.type == 'series' ? 'tv' : 'ft',
          });

  final String title;
  final Uri url;

  static Uri? _imdbUrl(String? id) {
    if (id == null || !RegExp(r'^tt\d+$').hasMatch(id)) return null;
    return Uri.https('www.imdb.com', '/title/$id/');
  }

  bool get isImdb => url.host == 'www.imdb.com';

  String get caption => title;

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
    final glass = GlassChrome.enabled(AppThemeScope.of(context));
    final copied = await showModalBottomSheet<bool>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: glass ? Colors.transparent : const Color(0xFF17191D),
      constraints: const BoxConstraints(maxWidth: 520),
      builder: (_) => glass
          ? GlassSurface(child: _ReelShareSheet(content: content))
          : _ReelShareSheet(content: content),
    );
    if (copied == true && context.mounted) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(const SnackBar(content: Text('Link copied')));
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
      ).launchChooser('Share title');
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
          _error = 'Could not open the link. Copy it to share instead.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final content = widget.content;
    final app = AppThemeScope.of(context);
    final glass = GlassChrome.enabled(app);
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Share title',
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
          const SizedBox(height: 18),
          DecoratedBox(
            decoration: glass
                ? GlassChrome.decoration(app, radius: BorderRadius.circular(14))
                : BoxDecoration(
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
              backgroundColor: glass
                  ? GlassChrome.fill(app, raised: true)
                  : Colors.white,
              foregroundColor: glass ? app.core.tx : Colors.black,
              shape: glass ? GlassChrome.shape(app, active: true) : null,
              minimumSize: const Size.fromHeight(50),
            ),
            icon: const Icon(Icons.link_rounded),
            label: const Text('Copy link'),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _busy ? null : _open,
            style: TextButton.styleFrom(
              foregroundColor: glass ? app.core.tx : Colors.white,
              minimumSize: const Size.fromHeight(48),
            ),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: Text(content.isImdb ? 'Open in IMDb' : 'Open clip'),
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
