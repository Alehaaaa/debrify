import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/app_motion.dart';
import '../theme/app_theme_scope.dart';
import '../theme/glass_chrome.dart';
import '../models/profiles/user_profile.dart';
import 'launch/launch_ident.dart' show identMarkSheen, identPlayPath;
import 'menu_pill.dart';
import 'profiles/profile_avatar_view.dart';
import 'desktop_sidebar_nav.dart' show DesktopNavEntry;

/// The pointer-world sibling of the TV rail's 'pill' style: no rail at all —
/// content runs full-bleed and a shared bottom-right Menu pill opens the menu
/// as an overlay panel over
/// the page; picking an entry, clicking away or pressing Escape closes it.
///
/// Deliberately NOT a reuse of [TvSidebarNav]'s pill: that one is welded to
/// the DPAD focus model (skip-traversal nodes, the LEFT-only door, edge glow
/// driven by where content focus sits). This one is pure pointer — hover and
/// click.
///
/// Mounted as a `Positioned.fill` layer over the content. Its base Stack has
/// no full-screen hit surface while closed — only the capsule itself is
/// clickable — so the page underneath keeps every interaction.
class DesktopPillNav extends StatefulWidget {
  /// Index into [entries] of the active screen.
  final int currentIndex;
  final List<DesktopNavEntry> entries;

  /// Called with the index into [entries] that was picked.
  final ValueChanged<int> onTap;

  /// Finger-sized targets (touch tablets — iPad / Android tablet).
  final bool expanded;
  final UserProfile? profile;
  final VoidCallback? onProfileTap;

  const DesktopPillNav({
    super.key,
    required this.currentIndex,
    required this.entries,
    required this.onTap,
    this.expanded = false,
    this.profile,
    this.onProfileTap,
  });

  /// Handles for tests.
  static const Key pillKey = ValueKey('desktop-sidebar-pill');
  static const Key scrimKey = ValueKey('desktop-sidebar-scrim');
  static const Key panelKey = ValueKey('desktop-sidebar-panel');

  @override
  State<DesktopPillNav> createState() => _DesktopPillNavState();
}

class _DesktopPillNavState extends State<DesktopPillNav> {
  bool _open = false;

  /// Escape-to-close. Requested on open, released on close, so the page's
  /// own keyboard handling is untouched while the menu is shut.
  final FocusNode _panelFocus = FocusNode(debugLabel: 'desktop-pill-panel');

  /// Whatever held keyboard focus when the panel opened (a search field,
  /// mid-word). Restored on the close paths that stay on the same tab —
  /// scrim, Escape — so opening the menu to peek never costs the user their
  /// caret. A pick switches tabs and deliberately does not restore.
  FocusNode? _restoreFocus;

  /// True from open until the scrim's CLOSE fade finishes. The modal hit
  /// surface must outlive `_open` by the fade: dropping it the instant the
  /// scrim starts fading lets a quick second click land on whatever page
  /// control happens to sit under the pointer.
  bool _scrimBlocking = false;

  @override
  void dispose() {
    _panelFocus.dispose();
    super.dispose();
  }

  void _openPanel() {
    final prev = FocusManager.instance.primaryFocus;
    // A bare scope means nothing real was focused — nothing to give back.
    _restoreFocus =
        (prev != null && prev != _panelFocus && prev is! FocusScopeNode)
        ? prev
        : null;
    setState(() {
      _open = true;
      _scrimBlocking = true;
    });
    _panelFocus.requestFocus();
  }

  void _close({bool restoreFocus = true}) {
    if (!_open) return;
    // _scrimBlocking stays true — the scrim's onEnd clears it when the
    // close fade lands.
    setState(() => _open = false);
    final prev = _restoreFocus;
    _restoreFocus = null;
    if (restoreFocus &&
        prev != null &&
        (prev.context?.mounted ?? false) &&
        prev.canRequestFocus) {
      prev.requestFocus();
    } else {
      _panelFocus.unfocus();
    }
  }

  void _pick(int i) {
    _close(restoreFocus: false);
    widget.onTap(i);
  }

  @override
  Widget build(BuildContext context) {
    final motion = AppMotion.of(context);
    final slide = motion.scaled(const Duration(milliseconds: 200));
    // This layer is a Positioned.fill OVER the shell's SafeArea, so system
    // insets (an iPad/landscape-cutout left notch, a status bar) must be
    // taken here — the scrim stays full-bleed on purpose, but the capsule
    // and the panel's content have to stay reachable.
    final insets = MediaQuery.paddingOf(context);
    return Stack(
      children: [
        // Scrim — always mounted so open/close cross-fades. The hit surface
        // outlives `_open` by the fade (see _scrimBlocking) so a quick
        // second click can't reach the page through a half-faded veil.
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_open && !_scrimBlocking,
            child: AnimatedOpacity(
              opacity: _open ? 1 : 0,
              duration: slide,
              curve: Curves.easeOut,
              onEnd: () {
                if (!_open && mounted) {
                  setState(() => _scrimBlocking = false);
                }
              },
              child: GestureDetector(
                key: DesktopPillNav.scrimKey,
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                child: ColoredBox(
                  color: AppThemeScope.of(context).shell.sidebarScrim,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          right: 0,
          top: 0,
          bottom: 0,
          child: IgnorePointer(
            ignoring: !_open,
            child: AnimatedSlide(
              // The bottom-right Menu pill opens a genuine edge-connected
              // sidebar. Keep it fully off-screen while closed so it never
              // reads as a persistent popup.
              offset: _open ? Offset.zero : const Offset(1.1, 0),
              duration: slide,
              curve: Curves.easeOutCubic,
              child: _panel(context),
            ),
          ),
        ),
        // Same bottom-right anchor as phone navigation. The scrim and Escape
        // dismiss the open drawer, so the trigger stays cleanly out of its
        // way while the sidebar is visible.
        Positioned(
          right: 16 + insets.right,
          bottom: 32 + insets.bottom,
          child: AnimatedOpacity(
            opacity: _open ? 0 : 1,
            duration: slide,
            child: IgnorePointer(ignoring: _open, child: _pill(context)),
          ),
        ),
      ],
    );
  }

  Widget _pill(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: MenuPill(
        pillKey: DesktopPillNav.pillKey,
        isOpen: _open,
        onTap: _openPanel,
      ),
    );
  }

  Widget _panel(BuildContext context) {
    final app = AppThemeScope.of(context);
    final frosted = GlassChrome.enabled(app);
    final width = widget.expanded ? 268.0 : 236.0;
    final children = <Widget>[];
    String? lastSection;
    for (var i = 0; i < widget.entries.length; i++) {
      final e = widget.entries[i];
      if (lastSection != null && e.section != lastSection) {
        children.add(
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7),
            child: Container(height: 1, color: app.fade(app.core.tx, 0.06)),
          ),
        );
      }
      lastSection = e.section;
      children.add(
        _PanelItem(
          icon: e.icon,
          label: e.label,
          selected: i == widget.currentIndex,
          expanded: widget.expanded,
          onTap: () => _pick(i),
        ),
      );
    }
    return Focus(
      focusNode: _panelFocus,
      onKeyEvent: (_, e) {
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
          _close();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        key: DesktopPillNav.panelKey,
        width: width,
        decoration: BoxDecoration(
          boxShadow: const [
            BoxShadow(
              color: Color(0x73000000),
              blurRadius: 32,
              offset: Offset(-6, 0),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: const BorderRadius.horizontal(
            left: Radius.circular(24),
          ),
          child: Stack(
            children: [
              Positioned.fill(
                // Filter the artwork behind the drawer, but keep the drawer
                // contents in a sibling layer. Procedural profile art uses a
                // screen blend and otherwise gets flattened by this filter.
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      // This drawer sits OVER page art, unlike the fixed rail. A
                      // low-opacity, two-tone tint lets that art diffuse through
                      // and makes the material visibly read as frosted glass.
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          app.shell.railBg.withValues(
                            alpha: frosted ? 0.53 : 0.62,
                          ),
                          (frosted ? GlassChrome.fill(app) : app.shell.ink)
                              .withValues(alpha: frosted ? 0.64 : 0.52),
                        ],
                      ),
                      border: Border(
                        left: BorderSide(
                          color: frosted
                              ? GlassChrome.edge(app)
                              : app.fade(app.core.tx, 0.20),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // The panel's INK runs edge to edge; its content steps inside
              // the system insets (cutout on the right, status bar up top) so
              // every row stays tappable.
              SafeArea(
                left: false,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 26, 20, 14),
                      child: Row(
                        children: [
                          // The splash file is a wide lockup. This compact
                          // header uses its square companion artwork instead.
                          Image(
                            image: const ExactAssetImage(
                              'assets/app_icon_foreground.png',
                            ),
                            width: 32,
                            height: 32,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) =>
                                const _DebrifyHeaderMark(),
                          ),
                          const SizedBox(width: 9),
                          Text(
                            'Nextup',
                            style: TextStyle(
                              color: app.fade(app.core.tx, 0.82),
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.1,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.only(top: 2, bottom: 16),
                        children: children,
                      ),
                    ),
                    if (widget.profile != null && widget.onProfileTap != null)
                      _PanelProfile(
                        profile: widget.profile!,
                        expanded: widget.expanded,
                        onTap: () {
                          _close(restoreFocus: false);
                          widget.onProfileTap!();
                        },
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

/// The vector form of the same Debrify ribbon used in the launch logo. It is
/// only an asset-load fallback, never a replacement for the supplied artwork.
class _DebrifyHeaderMark extends StatelessWidget {
  const _DebrifyHeaderMark();

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: const _DebrifyHeaderMarkPainter(),
    size: const Size.square(32),
  );
}

class _DebrifyHeaderMarkPainter extends CustomPainter {
  const _DebrifyHeaderMarkPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    canvas.save();
    canvas.translate(size.width / 2, size.height / 2);
    final markSize = side * 1.38;
    final bounds = Rect.fromCenter(
      center: Offset.zero,
      width: markSize,
      height: markSize,
    );
    canvas.drawPath(
      identPlayPath(markSize),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF24E7F4), Color(0xFF069CF9), Color(0xFF123ED7)],
        ).createShader(bounds),
    );
    canvas.drawPath(
      identMarkSheen(markSize),
      Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.20),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _DebrifyHeaderMarkPainter oldDelegate) => false;
}

class _PanelProfile extends StatefulWidget {
  final UserProfile profile;
  final bool expanded;
  final VoidCallback onTap;

  const _PanelProfile({
    required this.profile,
    required this.expanded,
    required this.onTap,
  });

  @override
  State<_PanelProfile> createState() => _PanelProfileState();
}

class _PanelProfileState extends State<_PanelProfile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    return Padding(
      key: const ValueKey('desktop-pill-profile'),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 14),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: AppMotion.of(
              context,
            ).scaled(const Duration(milliseconds: 130)),
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: widget.expanded ? 11 : 9,
            ),
            decoration: BoxDecoration(
              color: _hovered
                  ? app.fade(app.core.tx, 0.06)
                  : Colors.transparent,
              borderRadius: app.shape.br(12),
              border: Border.all(color: app.fade(app.core.tx, 0.08)),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 36,
                  height: 36,
                  child: ClipOval(
                    child: ProfileAvatarView(
                      profileId: widget.profile.id,
                      avatarKey: widget.profile.avatarKey,
                      role: widget.profile.role,
                      name: widget.profile.name,
                      focused: true,
                      animateWhenIdle: true,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        widget.profile.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurface,
                          fontSize: widget.expanded ? 13.5 : 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        widget.profile.isAdmin ? 'Admin' : 'Profile',
                        style: TextStyle(
                          color: app.fade(app.core.tx, 0.48),
                          fontSize: 10.5,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 18,
                  color: app.fade(app.core.tx, 0.45),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One row of the overlay panel: icon + label, hover highlight, accent when
/// active. Horizontal rows rather than the rail's stacked icon cells — a
/// temporary menu reads top-to-bottom like a list, not like a dock.
class _PanelItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final bool expanded;
  final VoidCallback onTap;

  const _PanelItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.expanded,
    required this.onTap,
  });

  @override
  State<_PanelItem> createState() => _PanelItemState();
}

class _PanelItemState extends State<_PanelItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    final motion = AppMotion.of(context);
    final cs = Theme.of(context).colorScheme;
    final Color fg = widget.selected
        ? app.shell.navAccent
        : (_hovered ? cs.onSurface : app.fade(app.core.tx, 0.62));
    final Color bg = widget.selected
        ? app.shell.navAccent.withValues(alpha: 0.14)
        : (_hovered ? app.fade(app.core.tx, 0.05) : Colors.transparent);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) {
          if (mounted) setState(() => _hovered = true);
        },
        onExit: (_) {
          if (mounted) setState(() => _hovered = false);
        },
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: AnimatedContainer(
            duration: motion.scaled(const Duration(milliseconds: 130)),
            curve: Curves.easeOut,
            padding: EdgeInsets.symmetric(
              horizontal: 12,
              vertical: widget.expanded ? 12 : 9,
            ),
            decoration: BoxDecoration(
              gradient: widget.selected
                  ? LinearGradient(
                      colors: [
                        app.shell.navAccent.withValues(alpha: 0.34),
                        app.shell.navAccent.withValues(alpha: 0.15),
                      ],
                    )
                  : null,
              color: widget.selected ? null : bg,
              borderRadius: app.shape.br(12),
              border: widget.selected
                  ? Border.all(
                      color: app.shell.navAccent.withValues(alpha: 0.26),
                    )
                  : null,
            ),
            child: Row(
              children: [
                Icon(widget.icon, size: widget.expanded ? 24 : 21, color: fg),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: fg,
                      fontSize: widget.expanded ? 13.5 : 12.5,
                      fontWeight: FontWeight.w600,
                    ),
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
