import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/stremio_addon.dart';
import '../theme/app_theme_scope.dart';
import '../theme/widgets/themed_artwork.dart';
import '../utils/dialog_tap_guard.dart';
import '../utils/tv_keys.dart';

/// One row of a [showCardActionMenu] menu.
class CardMenuAction<T> {
  final T value;
  final IconData icon;
  final String label;
  final String description;

  /// Draws the row in the danger tint (removals, deletes).
  final bool destructive;

  const CardMenuAction({
    required this.value,
    required this.icon,
    required this.label,
    required this.description,
    this.destructive = false,
  });
}

/// The hold / right-click menu for a title card in a library (Home rows,
/// Discover, Downloads). Returns the picked [CardMenuAction.value], or null
/// when dismissed.
///
/// A centered dialog rather than a bottom sheet so one presentation serves
/// every size: it's the same chrome the IPTV list picker uses (the app's other
/// "hold to open a menu" gesture), which keeps the DPAD story identical — first
/// row focused on open, up/down between rows, Back to dismiss.
///
/// The rows are passed in rather than derived here: each library knows what
/// "remove" or "play" means for its own cards.
Future<T?> showCardActionMenu<T>(
  BuildContext context, {
  required String title,
  required bool isTelevision,
  required List<CardMenuAction<T>> actions,
  String? posterUrl,
  String? subtitle,
}) {
  if (actions.isEmpty) return Future.value(null);
  return showDialog<T>(
    context: context,
    barrierDismissible: true,
    // A TV hold opens this dialog while OK is still physically down. Eat the
    // repeat tail before it can activate the autofocus row under the thumb.
    builder: (_) => TvHeldKeyGuard(
      child: _CardActionMenu<T>(
        title: title,
        isTelevision: isTelevision,
        posterUrl: posterUrl,
        subtitle: subtitle,
        actions: actions,
      ),
    ),
  );
}

class _CardActionMenu<T> extends StatefulWidget {
  final String title;
  final bool isTelevision;
  final String? posterUrl;
  final String? subtitle;
  final List<CardMenuAction<T>> actions;

  const _CardActionMenu({
    required this.title,
    required this.isTelevision,
    required this.posterUrl,
    required this.subtitle,
    required this.actions,
  });

  @override
  State<_CardActionMenu<T>> createState() => _CardActionMenuState<T>();
}

class _CardActionMenuState<T> extends State<_CardActionMenu<T>> {
  static const _accent = Color(0xFF8B5CF6);
  static const _danger = Color(0xFFF87171);

  late final List<FocusNode> _nodes = [
    for (var i = 0; i < widget.actions.length; i++)
      FocusNode(debugLabel: 'card-menu-$i'),
  ];

  @override
  void initState() {
    super.initState();
    // TV only: land the DPAD on the first row, never on the barrier — that
    // would leave the remote with nothing to press but Back. Touch/desktop open
    // with nothing highlighted, so no row reads as pre-selected.
    if (!widget.isTelevision) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _nodes.first.requestFocus();
    });
  }

  @override
  void dispose() {
    for (final node in _nodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _pick(T value) => Navigator.of(context).pop(value);

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final app = AppThemeScope.of(context);
    // Phones take the full width (minus the inset); anything wider caps at a
    // comfortable reading width so the rows never stretch into a banner.
    final maxWidth = size.width < 520 ? size.width : 430.0;
    return Dialog(
      // Tokenised with the ink, not after it: the rows below now draw their
      // text from `app.core.tx`, so a surface pinned dark would put a light
      // theme's near-black text on a near-black sheet.
      backgroundColor: app.sheetSurface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      shape: RoundedRectangleBorder(borderRadius: app.shape.br(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: maxWidth,
          maxHeight: size.height * 0.85,
        ),
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(),
                const SizedBox(height: 16),
                for (var i = 0; i < widget.actions.length; i++)
                  _MenuRow(
                    focusNode: _nodes[i],
                    icon: widget.actions[i].icon,
                    iconColor: widget.actions[i].destructive
                        ? _danger
                        : _accent,
                    accent: widget.actions[i].destructive ? _danger : _accent,
                    label: widget.actions[i].label,
                    description: widget.actions[i].description,
                    onTap: () => _pick(widget.actions[i].value),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final app = AppThemeScope.of(context);
    final poster = widget.posterUrl;
    final subtitle = widget.subtitle;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: 44,
          height: 66,
          // The poster's frame is the theme's, so [ThemedArtwork] owns the
          // clip this site used to draw for itself.
          child: ThemedArtwork(
            role: ArtRole.poster,
            radius: 8,
            builder: (context, blend) => (poster != null && poster.isNotEmpty)
                ? CachedNetworkImage(
                    imageUrl: poster,
                    fit: BoxFit.cover,
                    color: blend?.$1,
                    colorBlendMode: blend?.$2,
                    memCacheWidth: 132,
                    fadeInDuration: Duration.zero,
                    placeholder: (_, __) => const _PosterFallback(),
                    errorWidget: (_, __, ___) => const _PosterFallback(),
                  )
                : const _PosterFallback(),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 16.5,
                  fontWeight: FontWeight.w700,
                  height: 1.2,
                ),
              ),
              if (subtitle != null && subtitle.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: app.fade(app.core.tx, 0.5),
                    fontSize: 12.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _PosterFallback extends StatelessWidget {
  const _PosterFallback();

  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    return ColoredBox(
      color: app.fade(app.core.tx, 0.06),
      child: Icon(
        Icons.movie_rounded,
        size: 18,
        color: app.fade(app.core.tx, 0.3),
      ),
    );
  }
}

/// One focusable action row. Focus is drawn with the accent ring the TV
/// pickers use, so DPAD position is never ambiguous.
class _MenuRow extends StatefulWidget {
  final FocusNode focusNode;
  final IconData icon;
  final Color iconColor;
  final Color accent;
  final String label;
  final String description;
  final VoidCallback onTap;

  const _MenuRow({
    required this.focusNode,
    required this.icon,
    required this.iconColor,
    required this.accent,
    required this.label,
    required this.description,
    required this.onTap,
  });

  @override
  State<_MenuRow> createState() => _MenuRowState();
}

class _MenuRowState extends State<_MenuRow> {
  bool _focused = false;
  bool _hovered = false;
  bool get _active => _focused || _hovered;

  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (value) => setState(() => _focused = value),
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        if (isActivateOrSpaceKey(event.logicalKey)) {
          // DPAD Select also synthesizes a tap; mark it so the tap that
          // follows this key action doesn't fire the row a second time.
          DialogTapGuard.markKeyAction();
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: () {
            if (DialogTapGuard.shouldIgnoreTap()) return;
            widget.onTap();
          },
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 12),
            decoration: BoxDecoration(
              color: _active
                  ? widget.accent.withValues(alpha: 0.16)
                  : app.fade(app.core.tx, 0.04),
              borderRadius: app.shape.br(14),
              border: Border.all(
                color: _active ? widget.accent : app.fade(app.core.tx, 0.07),
                width: _active ? 2 : 1,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Icon(widget.icon, size: 22, color: widget.iconColor),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.label,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        widget.description,
                        style: TextStyle(
                          color: app.fade(app.core.tx, 0.5),
                          fontSize: 12.5,
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
      ),
    );
  }
}

/// Opens a library's card menu for [item]. [open] and [quickPlay] are the
/// grid's own tap / quick-play for that item, so the menu's Open and Play rows
/// do exactly what the card itself would.
typedef CardOptionsHandler =
    void Function(
      StremioMeta item, {
      required VoidCallback open,
      VoidCallback? quickPlay,
    });

/// Hands a library's card menu down to the poster grids inside it.
///
/// Discover swaps between half a dozen See-All panels (addon catalogs, Trakt,
/// Simkl, MDBList, Continue Watching…) that all draw through
/// [SeeAllPosterGrid]; this lets the host offer one menu to every one of them
/// without each panel growing a pass-through parameter. A grid outside any
/// scope keeps its old hold-to-Quick-Play behavior.
class CardOptionsScope extends InheritedWidget {
  final CardOptionsHandler onOptions;

  const CardOptionsScope({
    super.key,
    required this.onOptions,
    required super.child,
  });

  static CardOptionsHandler? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<CardOptionsScope>()?.onOptions;

  @override
  bool updateShouldNotify(CardOptionsScope oldWidget) =>
      oldWidget.onOptions != onOptions;
}

/// Tells a card-menu handler whether it was reached by a right-click rather
/// than a hold. Cards share one callback for both gestures; Home's "Hold to
/// Quick Play" preference only re-purposes the hold, so a right-click must
/// still open the menu. Read it synchronously, before the handler's first
/// await.
abstract final class CardMenuGesture {
  static bool _secondaryClick = false;

  /// True while a right-click is being dispatched.
  static bool get isSecondaryClick => _secondaryClick;

  /// Wraps [callback] for `onSecondaryTap`, flagging the call as a right-click.
  static VoidCallback? secondaryClick(VoidCallback? callback) {
    if (callback == null) return null;
    return () {
      _secondaryClick = true;
      try {
        callback();
      } finally {
        _secondaryClick = false;
      }
    };
  }
}
