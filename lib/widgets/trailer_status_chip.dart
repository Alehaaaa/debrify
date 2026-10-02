import 'dart:math';

import 'package:flutter/material.dart';

import '../theme/app_theme_scope.dart';
import '../utils/platform_util.dart';

/// The ambient trailer chip shared by the Home Spotlight hero and the detail
/// page backdrop: one quiet glass capsule reading "TRAILER" from
/// the moment a trailer starts resolving until it stops. Only its leading
/// glyph changes, cross-fading in place:
///
/// * resolving/buffering: a small amber spinner;
/// * playing: three amber equalizer bars rolling as a wave (resting flat
///   while muted, and still on TV, whose effects budget bans continuous idle
///   animation over the video);
/// * hovered while playing (pointer platforms): the bars become the speaker
///   button, the same icons as the detail page's "Trailer playing" chip.
///   Touch has no hover, so a tap anywhere on the chip toggles the sound.
///
/// Cheap by construction: no blur (weak-TV rule), the glyph is a ~14px
/// repaint inside its own RepaintBoundary, and the wave controller only runs
/// while it is actually drawn, so the hidden chip costs nothing.
class TrailerStatusChip extends StatefulWidget {
  /// Resolving/buffering: the spinner glyph. Wins over [playing].
  final bool loading;

  /// Frames on screen: the wave glyph.
  final bool playing;

  /// Whether the trailer is currently audible.
  final bool soundOn;

  /// Null keeps the chip a pure, pointer-transparent status (TV, or a host
  /// that cannot change the sound).
  final VoidCallback? onSoundToggle;

  const TrailerStatusChip({
    required this.loading,
    required this.playing,
    this.soundOn = false,
    this.onSoundToggle,
  });

  @override
  State<TrailerStatusChip> createState() => _TrailerStatusChipState();
}

class _TrailerStatusChipState extends State<TrailerStatusChip>
    with SingleTickerProviderStateMixin {
  // Created EAGERLY in initState: a `late` field first reached by dispose()
  // would create its Ticker there — a TickerMode ancestor lookup on a defunct
  // context (debug assertion crash).
  late final AnimationController _wave;
  bool _hovered = false;

  bool get _visible => widget.loading || widget.playing;
  bool get _playingNow => widget.playing && !widget.loading;
  bool get _interactive => widget.onSoundToggle != null && _playingNow;
  bool get _hoverReveal => PlatformUtil.isDesktop;
  bool get _showButton => _interactive && _hoverReveal && _hovered;

  /// The wave rolls whenever it is the visible glyph (still on TV).
  bool get _waveRuns =>
      _playingNow && !_showButton && !PlatformUtil.isTelevision;

  /// The interactive chip is painted and hit-tested in the route's overlay,
  /// positioned from this slot's laid-out location. Both hosts mount it in a
  /// backdrop layer that sits BEHIND scrolling page content, which wins every
  /// pointer hit test over it — so a chip left in place never sees a hover or
  /// a tap. The overlay keeps it above the page but below later routes.
  ///
  /// Hosts position the chip by its TOP-RIGHT corner (`top` + `right`): the
  /// overlay copy hangs leftwards from that point.
  final OverlayPortalController _portal = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    _wave = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    );
    _syncWave();
    if (widget.onSoundToggle != null) _portal.show();
  }

  @override
  void didUpdateWidget(TrailerStatusChip old) {
    super.didUpdateWidget(old);
    if (!_interactive) _hovered = false;
    if (widget.onSoundToggle != null && !_portal.isShowing) _portal.show();
    _syncWave();
  }

  void _syncWave() {
    if (_waveRuns && !_wave.isAnimating) {
      _wave.repeat();
    } else if (!_waveRuns && _wave.isAnimating) {
      _wave.stop();
    }
  }

  void _setHovered(bool hovered) {
    if (_hovered == hovered) return;
    setState(() => _hovered = hovered);
    _syncWave();
  }

  @override
  void dispose() {
    _wave.dispose();
    super.dispose();
  }

  /// One equalizer bar: bottom-anchored, height riding a phase-shifted sine
  /// so the three bars roll as a wave rather than pumping in unison. Flat
  /// (and still) when [rolling] is false — TV only.
  Widget _bar(Color color, double t, double phase, bool rolling) {
    final f = rolling
        ? 0.30 + 0.70 * (0.5 + 0.5 * sin(2 * pi * (t + phase)))
        : 0.30;
    return Container(
      width: 2.5,
      height: 11 * f,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(1.5),
      ),
    );
  }

  Widget _glyph(BuildContext context) {
    final app = AppThemeScope.of(context);
    final ink = app.home.highlight;
    if (widget.loading) {
      return SizedBox(
        key: const ValueKey('loading'),
        width: 11,
        height: 11,
        child: CircularProgressIndicator(
          strokeWidth: 1.6,
          valueColor: AlwaysStoppedAnimation<Color>(ink),
        ),
      );
    }
    if (_showButton) {
      return Icon(
        widget.soundOn ? Icons.volume_up_rounded : Icons.volume_off_rounded,
        key: ValueKey<String>('sound-${widget.soundOn}'),
        size: 14,
        color: app.fade(app.core.tx, 0.9),
      );
    }
    final rolling = !PlatformUtil.isTelevision;
    return SizedBox(
      key: const ValueKey('wave'),
      width: 13,
      height: 11,
      child: AnimatedBuilder(
        animation: _wave,
        builder: (context, _) {
          final t = _wave.value;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _bar(ink, t, 0.0, rolling),
              _bar(ink, t, 0.30, rolling),
              _bar(ink, t, 0.60, rolling),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    final visible = _visible;
    final interactive = _interactive;
    Widget chip = AnimatedSlide(
      offset: visible ? Offset.zero : const Offset(0, -0.25),
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
      child: AnimatedOpacity(
        opacity: visible ? 1 : 0,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOut,
        // RepaintBoundary: the spinner and wave produce a frame per vsync —
        // without the boundary each would dirty the ROUTE's layer.
        child: RepaintBoundary(
          child: Container(
            padding: const EdgeInsets.fromLTRB(11, 6, 12, 6),
            decoration: BoxDecoration(
              // Glassy page ink — fade 0.8 pins the legacy 0xCC alpha.
              color: app.fade(app.home.bg, _showButton ? 0.9 : 0.8),
              borderRadius: app.shape.brPill,
              border: Border.all(
                color: app.fade(app.core.tx, _showButton ? 0.28 : 0.16),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, animation) => FadeTransition(
                        opacity: animation,
                        child: ScaleTransition(
                          scale: Tween<double>(
                            begin: 0.6,
                            end: 1,
                          ).animate(animation),
                          child: child,
                        ),
                      ),
                      child: _glyph(context),
                    ),
                  ),
                ),
                const SizedBox(width: 7),
                Text(
                  'TRAILER',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                    color: app.fade(app.core.tx, 0.62),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (interactive) {
      chip = Tooltip(
        message: widget.soundOn ? 'Mute trailer' : 'Unmute trailer',
        child: Semantics(
          button: true,
          label: widget.soundOn ? 'Mute trailer' : 'Unmute trailer',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onSoundToggle,
            child: chip,
          ),
        ),
      );
    }
    // Status-only (TV, Discover): plain, pointer-transparent, in place.
    if (widget.onSoundToggle == null) return IgnorePointer(child: chip);
    final live = IgnorePointer(
      ignoring: !interactive,
      child: MouseRegion(
        cursor: interactive ? SystemMouseCursors.click : MouseCursor.defer,
        onEnter: (_) => _setHovered(interactive),
        onExit: (_) => _setHovered(false),
        child: chip,
      ),
    );
    // The in-place anchor is zero-sized at the slot's top-right corner (the
    // host positions this widget by `top`/`right`); the overlay copy hangs
    // leftwards from it, exactly where the in-place chip used to paint.
    // Positioned from LAYOUT info, not a CompositedTransformFollower: the
    // chip's Tooltip needs its paint transform during layout, which a
    // follower only establishes at paint time.
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayChildBuilder: (context, info) {
        final anchor = MatrixUtils.transformPoint(
          info.childPaintTransform,
          Offset.zero,
        );
        return Positioned(
          top: anchor.dy,
          right: info.overlaySize.width - anchor.dx,
          child: live,
        );
      },
      child: const SizedBox.shrink(),
    );
  }
}
