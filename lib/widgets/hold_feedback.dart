import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/ui_feedback.dart';
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

/// Press feedback for a card.
///
/// **Pointer** (touch, mouse): the ripple and highlight the calendar's rows
/// get from their `InkWell` — a soft wash plus a circle spreading from the
/// finger while it stays down, fading on release. Material ink can't do this
/// for a poster card: ink paints on the Material *behind* the card, so opaque
/// artwork hides it. This paints the same thing on top instead.
///
/// The press is watched with a [Listener], so this never joins the gesture
/// arena: the card's own [GestureDetector] still decides tap vs long-press.
/// A drag past touch slop (a scroll) drops the ripple.
///
/// **TV**: a held OK has no pointer; the card's key handler drives the dim +
/// filling ring Home's TV cards draw toward the moment the hold menu opens,
/// through [controller].
class HoldFeedback extends StatefulWidget {
  final Widget child;

  /// Draw the pointer ripple. Off where the card already has an `InkWell`.
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
  /// TV hold ring (0 → 1 over the dwell).
  late final AnimationController _ring = AnimationController(vsync: this)
    ..addStatusListener((status) {
      // The hold fired (the card opens its menu now); clear the ring.
      if (status == AnimationStatus.completed) _ring.value = 0;
    });

  /// Ripple spread (0 → 1 covers the card). Slow while held, like ink's own
  /// ripple, and hurried to full on release.
  late final AnimationController _spread = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 600),
  );

  /// Ripple + highlight fade-out after release (0 = fully shown).
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  );

  int? _pointer;
  Offset? _downAt;
  Offset _origin = Offset.zero;
  bool _pressed = false;

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
    _ring.dispose();
    _spread.dispose();
    _fade.dispose();
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
    _pressed = true;
    _fade.value = 0;
    _spread.forward(from: 0);
  }

  void _onMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _downAt == null) return;
    // A scroll or drag, not a press: let the ripple go quietly.
    if ((event.position - _downAt!).distance > kTouchSlop) _release(fast: true);
  }

  void _onEnd(PointerEvent event) {
    if (event.pointer == _pointer) _release();
  }

  void _release({bool fast = false}) {
    _pointer = null;
    _downAt = null;
    if (!_pressed) return;
    _pressed = false;
    if (fast) {
      _fade.forward(from: 0);
      return;
    }
    // Finish the spread, then fade — so even a quick tap shows the ripple.
    _spread
        .animateTo(1, duration: const Duration(milliseconds: 160))
        .whenCompleteOrCancel(() {
          if (mounted && !_pressed) _fade.forward(from: 0);
        });
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      // Sees the press even where the card paints nothing hit-testable,
      // without taking it from anything behind.
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onEnd,
      onPointerCancel: _onEnd,
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: Listenable.merge([_spread, _fade]),
                builder: (context, _) {
                  final visible =
                      (_pressed || _spread.value > 0) && _fade.value < 1;
                  if (!visible) return const SizedBox.shrink();
                  return CustomPaint(
                    painter: _RipplePainter(
                      origin: _origin,
                      spread: Curves.easeOut.transform(_spread.value),
                      opacity: 1 - _fade.value,
                      borderRadius: widget.borderRadius,
                    ),
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
    );
  }
}

/// The pressed wash plus the spreading circle, clipped to the card.
class _RipplePainter extends CustomPainter {
  final Offset origin;
  final double spread;
  final double opacity;
  final BorderRadius borderRadius;

  _RipplePainter({
    required this.origin,
    required this.spread,
    required this.opacity,
    required this.borderRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.save();
    canvas.clipRRect(borderRadius.toRRect(rect));
    // Highlight: the whole card lifts a shade while pressed.
    canvas.drawRect(
      rect,
      Paint()..color = Colors.white.withValues(alpha: 0.06 * opacity),
    );
    // Ripple: grows from the finger to the farthest corner.
    final reach = [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ].map((c) => (c - origin).distance).reduce(math.max);
    canvas.drawCircle(
      origin,
      reach * (0.12 + 0.88 * spread),
      Paint()..color = Colors.white.withValues(alpha: 0.16 * opacity),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_RipplePainter old) =>
      old.origin != origin ||
      old.spread != spread ||
      old.opacity != opacity ||
      old.borderRadius != borderRadius;
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
