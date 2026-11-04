import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';

/// Throws a frosted watchlist bubble from [origin].
///
/// It receives a short upward impulse, then falls completely below the screen.
/// A small random sideways drift and rotation keep repeated additions playful
/// without hiding the page underneath.
WatchlistAddedBubbleHandle? showWatchlistAddedBubble(
  BuildContext context, {
  Offset? origin,
}) {
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  if (overlay == null) return null;

  final overlayBox = overlay.context.findRenderObject() as RenderBox?;
  final localOrigin = origin == null || overlayBox == null
      ? null
      : overlayBox.globalToLocal(origin);

  late final OverlayEntry entry;
  final handle = WatchlistAddedBubbleHandle._(() {
    if (entry.mounted) entry.remove();
  });
  entry = OverlayEntry(
    builder: (_) => _WatchlistAddedBubble(
      onDismissed: handle.dismiss,
      origin: localOrigin,
      random: math.Random(),
    ),
  );
  overlay.insert(entry);
  return handle;
}

/// Allows an optimistic bubble to be removed when its watchlist write fails.
class WatchlistAddedBubbleHandle {
  WatchlistAddedBubbleHandle._(this._dismiss);

  final VoidCallback _dismiss;
  bool _dismissed = false;

  void dismiss() {
    if (_dismissed) return;
    _dismissed = true;
    _dismiss();
  }
}

class _WatchlistAddedBubble extends StatefulWidget {
  final VoidCallback onDismissed;
  final Offset? origin;
  final math.Random random;

  const _WatchlistAddedBubble({
    required this.onDismissed,
    required this.origin,
    required this.random,
  });

  @override
  State<_WatchlistAddedBubble> createState() => _WatchlistAddedBubbleState();
}

class _WatchlistAddedBubbleState extends State<_WatchlistAddedBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller =
      AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 720),
      )..addStatusListener((status) {
        if (status == AnimationStatus.completed) widget.onDismissed();
      });

  late final double _tilt = (widget.random.nextDouble() - .5) * .7;
  late final double _drift = (widget.random.nextDouble() - .5) * 70;

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          const diameter = 88.0;
          final start =
              widget.origin ??
              Offset(constraints.maxWidth * .5, constraints.maxHeight * .62);
          // One constant acceleration carries the bubble through its apex and
          // below the viewport, so the direction change has no visible seam.
          final launchVelocity = math.min(440.0, constraints.maxHeight * .54);
          final gravity =
              constraints.maxHeight - start.dy + diameter + launchVelocity;
          return AnimatedBuilder(
            animation: _controller,
            builder: (context, child) {
              final t = _controller.value;
              // s = 0 starts at the press. `-v * t + g * t²` is continuous
              // gravity: velocity reaches zero at the apex, then increases
              // downward without a bounce or a direction switch.
              final x = start.dx - diameter / 2 + _drift * t * t;
              final y =
                  start.dy -
                  diameter / 2 -
                  launchVelocity * t +
                  gravity * t * t;
              // The circle is born at the press point, then settles at its
              // full size before the gravity arc has meaningfully moved it.
              final scale = Curves.easeOutBack.transform(
                (t / .16).clamp(0.0, 1.0),
              );

              return Align(
                alignment: Alignment.topLeft,
                child: Transform.translate(
                  offset: Offset(x, y),
                  child: Transform.rotate(
                    angle: _tilt * t,
                    child: Transform.scale(scale: scale, child: child),
                  ),
                ),
              );
            },
            child: Semantics(
              liveRegion: true,
              label: 'Added to My Watchlist',
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white38),
                  boxShadow: const [
                    BoxShadow(
                      color: Colors.black45,
                      blurRadius: 20,
                      offset: Offset(0, 10),
                    ),
                  ],
                ),
                child: ClipOval(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: SizedBox.square(
                      dimension: diameter,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          color: Color(0x44D8F3FF),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.bookmark_added_rounded,
                          color: Colors.white,
                          size: 42,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
