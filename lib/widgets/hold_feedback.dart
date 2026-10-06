import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// Lets a card's own key handler drive its [HoldFeedback] — a held OK on TV
/// has no pointer for the overlay to watch.
class HoldFeedbackController {
  _HoldFeedbackState? _state;

  /// Start filling the ring over [duration] (the card's hold dwell).
  void start(Duration duration) => _state?._start(duration);

  /// Hide the ring: the press ended, moved away, or the hold already fired.
  void cancel() => _state?._cancel();
}

/// The hold overlay: while a card is pressed and held, it dims and a ring
/// fills toward the moment the hold menu opens — what Home's TV cards have
/// always drawn, for every card with a hold action and every input.
///
/// Touch and mouse holds are watched with a [Listener], so this never takes
/// part in the gesture arena: the card's own [GestureDetector] still decides
/// tap vs long-press, and the ring's [kLongPressTimeout] fill ends when its
/// long-press fires. The ring only shows once a press has lasted a moment, so
/// ordinary taps never flash it. TV key handlers drive it through
/// [controller] instead.
class HoldFeedback extends StatefulWidget {
  final Widget child;

  /// Watch pointer holds. Off when the card has no hold action.
  final bool enabled;
  final HoldFeedbackController? controller;
  final BorderRadius borderRadius;

  const HoldFeedback({
    super.key,
    required this.child,
    this.enabled = true,
    this.controller,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  @override
  State<HoldFeedback> createState() => _HoldFeedbackState();
}

class _HoldFeedbackState extends State<HoldFeedback>
    with SingleTickerProviderStateMixin {
  /// Fraction of the dwell before anything is drawn — a tap is over by then.
  static const double _showFrom = 0.25;

  late final AnimationController _fill = AnimationController(vsync: this)
    ..addStatusListener((status) {
      // The hold fired (the card opens its menu now); clear the ring.
      if (status == AnimationStatus.completed) _fill.value = 0;
    });

  int? _pointer;
  Offset? _downAt;

  @override
  void initState() {
    super.initState();
    widget.controller?._state = this;
  }

  @override
  void didUpdateWidget(HoldFeedback oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (oldWidget.controller?._state == this) oldWidget.controller!._state = null;
      widget.controller?._state = this;
    }
    if (!widget.enabled && _pointer != null) _cancel();
  }

  @override
  void dispose() {
    if (widget.controller?._state == this) widget.controller!._state = null;
    _fill.dispose();
    super.dispose();
  }

  void _start(Duration duration) {
    _fill
      ..duration = duration
      ..forward(from: 0);
  }

  void _cancel() {
    _pointer = null;
    _downAt = null;
    _fill
      ..stop()
      ..value = 0;
  }

  void _onDown(PointerDownEvent event) {
    if (!widget.enabled || _pointer != null) return;
    final touchLike =
        event.kind == PointerDeviceKind.touch ||
        event.kind == PointerDeviceKind.stylus;
    final primaryMouse =
        event.kind == PointerDeviceKind.mouse &&
        event.buttons == kPrimaryMouseButton;
    if (!touchLike && !primaryMouse) return;
    _pointer = event.pointer;
    _downAt = event.position;
    _start(kLongPressTimeout);
  }

  void _onMove(PointerMoveEvent event) {
    if (event.pointer != _pointer || _downAt == null) return;
    // A scroll or drag, not a hold.
    if ((event.position - _downAt!).distance > kTouchSlop) _cancel();
  }

  void _onEnd(PointerEvent event) {
    if (event.pointer == _pointer) _cancel();
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
                animation: _fill,
                builder: (context, _) {
                  final t = _fill.value;
                  if (t < _showFrom) return const SizedBox.shrink();
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

/// The overlay itself: a dim over the card and a ring filling to [progress].
/// Home's TV cards draw this from their own controllers.
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
