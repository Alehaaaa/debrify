import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/ui_feedback.dart';
import 'card_action_menu.dart';
import '../utils/tv_keys.dart';

/// The one hold recogniser for a card: OK opens on release (with the app's
/// activation feedback, see [withTapFeedback]), a held OK
/// ([kHoldDuration]) fires [onHold] under the thumb, and [ring] draws the
/// card's [HoldFeedback] filling toward that moment. Feed it the activation
/// keys from the card's `onKeyEvent`; [reset] it when focus leaves.
///
/// Touch and mouse holds stay with the card's `GestureDetector.onLongPress`
/// (same [kHoldDuration]); wrap that callback in [withHoldHaptic].
class CardHold {
  CardHold({
    required VoidCallback onTap,
    required VoidCallback onHold,
    bool Function()? canHold,
  }) : _canHold = canHold {
    _ok = TvHoldOk(
      onTap: withTapFeedback(onTap),
      onHold: () {
        ring.cancel();
        onHold();
      },
      canHold: canHold,
    );
  }

  final bool Function()? _canHold;
  late final TvHoldOk _ok;
  final HoldFeedbackController ring = HoldFeedbackController();

  KeyEventResult handle(KeyEvent event) {
    if (event is KeyDownEvent && (_canHold?.call() ?? true)) {
      ring.start(_ok.dwell);
    } else if (event is KeyUpEvent) {
      ring.cancel();
    }
    return _ok.handle(event);
  }

  void reset() {
    _ok.reset();
    ring.cancel();
  }
}

/// A card press with the app's activation feedback — the theme's haptic and
/// sound, as the user's UI haptics/sounds settings allow ([UiFeedback]). Every
/// card's tap goes through this (and [CardHold] does it for OK), so Home,
/// Discover, Downloads and Debrify TV all answer a press the same way.
VoidCallback withTapFeedback(VoidCallback callback) => () {
  UiFeedback.instance.activate();
  callback();
};

/// A touch/mouse long-press callback with the buzz every hold in the app
/// gives (the TV hold buzzes inside [TvHoldOk]). Null stays null, so the
/// gesture stays unarmed.
VoidCallback? withHoldHaptic(VoidCallback? callback) {
  if (callback == null) return null;
  return () {
    HapticFeedback.mediumImpact();
    callback();
  };
}

/// Lets a card's own key handler drive its [HoldFeedback] ring — a held OK on
/// TV has no pointer to watch.
class HoldFeedbackController {
  _HoldFeedbackState? _state;

  /// Start filling the ring over [duration] (the card's hold dwell).
  void start(Duration duration) => _state?._startRing(duration);

  /// Hide the ring: the press ended, moved away, or the hold already fired.
  void cancel() => _state?._cancelRing();
}

/// Press feedback for a tile — the one every tile in the app wears.
///
/// **Pointer** (touch, mouse): a frosted-glass *hold*. A plain tap shows
/// nothing; once a press outlasts a short grace, the tile sinks a few percent
/// under the finger and a lens of real backdrop blur — a frosted disc with a
/// soft light tint and a bright glass rim — grows from the touch point while
/// the finger stays down. On release the lens floods the tile
/// and thaws away as the tile springs back. Painted on top of the tile
/// (Material ink paints *behind* it, where opaque artwork hides it), and the
/// blur only exists for the length of a press, so a resting grid costs
/// nothing.
///
/// The press is watched with a [Listener], so this never joins the gesture
/// arena: the tile's own [GestureDetector] still decides tap vs long-press.
/// A drag past touch slop (a scroll) lets the press go without the flood.
///
/// **TV**: a held OK has no pointer; the tile's key handler drives the dim +
/// filling ring toward the moment the hold menu opens, through [controller]
/// (see [CardHold]).
class HoldFeedback extends StatefulWidget {
  final Widget child;

  /// Draw the pointer press. Off for TV-only surfaces.
  final bool ripple;
  final HoldFeedbackController? controller;
  final BorderRadius borderRadius;

  const HoldFeedback({
    super.key,
    required this.child,
    this.ripple = true,
    this.controller,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  @override
  State<HoldFeedback> createState() => _HoldFeedbackState();
}

class _HoldFeedbackState extends State<HoldFeedback>
    with TickerProviderStateMixin {
  /// How far the tile sinks under a press.
  static const double _sink = 0.03;

  /// A press shows nothing until it has lasted this long: an ordinary tap
  /// (well under it) opens the tile without any glass. Past it the press is
  /// a hold in the making, and the lens grows over the rest of
  /// [kHoldDuration] — fully grown just as the hold menu opens.
  static const Duration _grace = Duration(milliseconds: 180);

  /// TV hold ring (0 → 1 over the dwell).
  late final AnimationController _ring = AnimationController(vsync: this)
    ..addStatusListener((status) {
      // The hold fired (the tile opens its menu now); clear the ring.
      if (status == AnimationStatus.completed) _ring.value = 0;
    });

  /// Lens growth while held (0 → 1 reaches the held size around the
  /// finger — it never buries the tile).
  late final AnimationController _spread = AnimationController(
    vsync: this,
    duration: kHoldDuration - _grace,
  );

  /// Release flood (0 → 1: the lens sweeps the whole tile as it thaws).
  late final AnimationController _flood = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
  );

  /// Press depth: quick in, springy out.
  late final AnimationController _depth = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 110),
    reverseDuration: const Duration(milliseconds: 420),
  );

  /// Lens thaw after release (0 = fully frosted).
  late final AnimationController _thaw = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  int? _pointer;
  Offset? _downAt;
  Offset _origin = Offset.zero;

  /// The glass is showing: the press outlasted [_grace].
  bool _pressed = false;

  /// Pending [_grace] for the press in progress.
  Timer? _arm;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
  }

  @override
  void didUpdateWidget(HoldFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller?._state == this) {
        oldWidget.controller!._state = null;
      }
      widget.controller?._state = this;
    }
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller!._state = null;
    _arm?.cancel();
    _ring.dispose();
    _spread.dispose();
    _flood.dispose();
    _depth.dispose();
    _thaw.dispose();
    super.dispose();
  }

  void _startRing(Duration duration) {
    _ring
      ..duration = duration
      ..forward(from: 0);
  }

  void _cancelRing() {
    _ring
      ..stop()
      ..value = 0;
  }

  void _onDown(PointerDownEvent event) {
    if (!widget.ripple || _pointer != null) return;
    final touchLike =
        event.kind == PointerDeviceKind.touch ||
        event.kind == PointerDeviceKind.stylus;
    final primaryMouse =
        event.kind == PointerDeviceKind.mouse &&
        event.buttons == kPrimaryMouseButton;
    if (!touchLike && !primaryMouse) return;
    _pointer = event.pointer;
    _downAt = event.position;
    _origin = event.localPosition;
    _arm?.cancel();
    _arm = Timer(_grace, _engage);
  }

  /// The press outlasted [_grace]: frost and sink.
  void _engage() {
    _arm = null;
    if (!mounted || _pointer == null) return;
    _pressed = true;
    _thaw.value = 0;
    _flood.value = 0;
    _spread.forward(from: 0);
    _depth.forward();
  }

  void _onMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _downAt == null) return;
    // A scroll or drag, not a press: let it go without the flood.
    if ((event.position - _downAt!).distance > kTouchSlop) _release(fast: true);
  }

  void _onEnd(PointerEvent event) {
    if (event.pointer == _pointer) _release();
  }

  void _release({bool fast = false}) {
    _pointer = null;
    _downAt = null;
    // Lifted inside the grace: a plain tap, which never shows the glass.
    _arm?.cancel();
    _arm = null;
    if (!_pressed) return;
    _pressed = false;
    _depth.reverse();
    // A held press lifting: the lens sweeps the tile while it thaws. A scroll
    // just lets the glass melt where it is.
    if (!fast) _flood.forward(from: 0);
    _thaw.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Sees the press even where the tile paints nothing hit-testable,
      // without taking it from anything behind.
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onEnd,
      onPointerCancel: _onEnd,
      child: AnimatedBuilder(
        animation: _depth,
        builder: (context, child) {
          final d = _depth.status == AnimationStatus.reverse
              ? Curves.easeOutBack.transform(_depth.value)
              : Curves.easeOut.transform(_depth.value);
          if (d == 0) return child!;
          return Transform.scale(scale: 1 - _sink * d, child: child);
        },
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            widget.child,
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: Listenable.merge([_spread, _flood, _thaw]),
                  builder: (context, _) {
                    final visible =
                        (_pressed || _spread.value > 0) && _thaw.value < 1;
                    if (!visible) return const SizedBox.shrink();
                    return _FrostLens(
                      origin: _origin,
                      grow: Curves.easeOutCubic.transform(_spread.value),
                      flood: Curves.easeOutCubic.transform(_flood.value),
                      strength: 1 - Curves.easeInCubic.transform(_thaw.value),
                      borderRadius: widget.borderRadius,
                    );
                  },
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _ring,
                  builder: (context, _) {
                    final t = _ring.value;
                    if (t == 0) return const SizedBox.shrink();
                    return HoldProgressLayer(
                      progress: t,
                      borderRadius: widget.borderRadius,
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The frosted-glass lens: real backdrop blur clipped to a circle around
/// [origin], a light radial tint, a sheen across the whole tile and a bright
/// rim on the lens edge. [grow] (0 → 1) sizes it while held — a contained
/// lens under the finger; [flood] (0 → 1) sweeps it to the tile's farthest
/// corner on release; [strength] (1 → 0) thaws all of it together.
class _FrostLens extends StatelessWidget {
  final Offset origin;
  final double grow;
  final double flood;
  final double strength;
  final BorderRadius borderRadius;

  /// The held lens: this share of the tile's short side, within bounds that
  /// keep it a finger-sized glass on a phone tile and on a big desktop one.
  static const double _heldShare = 0.45;
  static const double _heldMin = 44;
  static const double _heldMax = 120;
  static const double _blur = 8;

  const _FrostLens({
    required this.origin,
    required this.grow,
    required this.flood,
    required this.strength,
    required this.borderRadius,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        final rect = Offset.zero & size;
        // Far enough to reach the farthest corner, so the flood covers all.
        final reach = [
          rect.topLeft,
          rect.topRight,
          rect.bottomLeft,
          rect.bottomRight,
        ].map((c) => (c - origin).distance).reduce(math.max);
        final held = (size.shortestSide * _heldShare).clamp(_heldMin, _heldMax);
        final heldRadius = held * (0.35 + 0.65 * grow);
        final radius = heldRadius + (reach - heldRadius) * flood;
        final lens = Rect.fromCircle(center: origin, radius: radius);
        return ClipRRect(
          borderRadius: borderRadius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Sheen: the whole tile catches a little light under the press.
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Colors.white.withValues(alpha: 0.10 * strength),
                      Colors.white.withValues(alpha: 0.02 * strength),
                    ],
                  ),
                ),
              ),
              // The lens: frosted backdrop + tint, clipped to the circle.
              ClipOval(
                clipper: _RectClipper(lens),
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: _blur * strength,
                    sigmaY: _blur * strength,
                  ),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment(
                          size.width == 0
                              ? 0
                              : (origin.dx / size.width) * 2 - 1,
                          size.height == 0
                              ? 0
                              : (origin.dy / size.height) * 2 - 1,
                        ),
                        radius: size.shortestSide == 0
                            ? 1
                            : radius / size.shortestSide,
                        colors: [
                          Colors.white.withValues(alpha: 0.24 * strength),
                          Colors.white.withValues(alpha: 0.08 * strength),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              // Glass rim.
              CustomPaint(
                painter: _RimPainter(
                  lens: lens,
                  alpha: 0.42 * strength * (1 - flood),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _RectClipper extends CustomClipper<Rect> {
  final Rect rect;

  const _RectClipper(this.rect);

  @override
  Rect getClip(Size size) => rect;

  @override
  bool shouldReclip(_RectClipper oldClipper) => oldClipper.rect != rect;
}

class _RimPainter extends CustomPainter {
  final Rect lens;
  final double alpha;

  const _RimPainter({required this.lens, required this.alpha});

  @override
  void paint(Canvas canvas, Size size) {
    if (alpha <= 0) return;
    canvas.drawOval(
      lens.deflate(0.6),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(alpha: alpha),
            Colors.white.withValues(alpha: alpha * 0.25),
          ],
        ).createShader(lens),
    );
  }

  @override
  bool shouldRepaint(_RimPainter old) => old.lens != lens || old.alpha != alpha;
}

/// The TV hold overlay: a dim over the card and a ring filling to
/// [progress]. Home's TV cards draw this from their own controllers too.
class HoldProgressLayer extends StatelessWidget {
  final double progress;
  final BorderRadius borderRadius;
  final Color ringColor;

  const HoldProgressLayer({
    super.key,
    required this.progress,
    this.borderRadius = BorderRadius.zero,
    this.ringColor = const Color(0xFF8B5CF6),
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.42),
        child: Center(
          child: SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(
              value: progress,
              strokeWidth: 3,
              backgroundColor: Colors.white.withValues(alpha: 0.22),
              valueColor: AlwaysStoppedAnimation(ringColor),
            ),
          ),
        ),
      ),
    );
  }
}

/// Gives an existing tappable tile the app's hold: a held press opens
/// [onHold] (touch long-press with the hold buzz, right-click, or a held OK
/// on TV), with the frosted press while it's held. The tile keeps its own tap.
///
/// For tiles drawn by their own `InkWell` (or anything that activates through
/// the app's shortcuts): on TV the activation key reaches this wrapper's
/// [Focus] on its way up from the focused tile, before any shortcut turns it
/// into a tap, so [CardHold] can tell a press from a hold and call [onTap]
/// itself. The tile's Material splash is turned off underneath, so the glass
/// is the only press it shows. With [onHold] null this adds nothing.
class HoldableTile extends StatefulWidget {
  final Widget child;
  final VoidCallback onTap;
  final VoidCallback? onHold;
  final BorderRadius borderRadius;

  const HoldableTile({
    super.key,
    required this.child,
    required this.onTap,
    required this.onHold,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  @override
  State<HoldableTile> createState() => _HoldableTileState();
}

class _HoldableTileState extends State<HoldableTile> {
  late final CardHold _hold = CardHold(
    onTap: () => widget.onTap(),
    onHold: () => widget.onHold?.call(),
  );

  @override
  void dispose() {
    _hold.reset();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final onHold = widget.onHold;
    if (onHold == null) return widget.child;
    final theme = Theme.of(context);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        if (!focused) _hold.reset();
      },
      onKeyEvent: (_, event) => isActivateOrSpaceKey(event.logicalKey)
          ? _hold.handle(event)
          : KeyEventResult.ignored,
      child: GestureDetector(
        onLongPress: withHoldHaptic(onHold),
        onSecondaryTap: CardMenuGesture.secondaryClick(onHold),
        child: HoldFeedback(
          controller: _hold.ring,
          borderRadius: widget.borderRadius,
          child: Theme(
            data: theme.copyWith(
              splashFactory: NoSplash.splashFactory,
              highlightColor: Colors.transparent,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
