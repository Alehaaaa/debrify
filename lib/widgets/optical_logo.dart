import 'dart:math' show sqrt;

import 'package:flutter/material.dart';

/// A logo sized for equal VISUAL weight rather than to a fixed box.
///
/// Logos range from near-square marks to 10:1 wordmarks. Fitting all of them
/// into one box makes the long ones width-bound and tiny while the compact
/// ones fill it. Here every logo gets the same target [area], so its size
/// follows its own aspect ratio: height = sqrt(area / aspect), clamped to
/// [maxWidth] × [maxHeight] (aspect preserved).
class OpticalLogo extends StatefulWidget {
  /// Shared bounds, so the Home Spotlight and the detail page size a title's
  /// logo identically: the AREA is what logos share — a 3:1 wordmark lands
  /// at ~240×80, a long 8:1 one at ~390×49, a square mark at the height cap.
  /// Callers multiply by their own layout scale.
  static const double defaultMaxWidth = 480;
  static const double defaultMaxHeight = 104;
  static const double defaultArea = 80 * 80 * 3;

  final ImageProvider image;
  final Alignment alignment;
  final double maxWidth;
  final double maxHeight;
  final double area;

  const OpticalLogo({
    super.key,
    required this.image,
    required this.alignment,
    required this.maxWidth,
    required this.maxHeight,
    required this.area,
  });

  @override
  State<OpticalLogo> createState() => _OpticalLogoState();
}

class _OpticalLogoState extends State<OpticalLogo> {
  ImageStream? _stream;
  late final ImageStreamListener _listener = ImageStreamListener(_onImage);

  /// width / height of the decoded art; null until the stream reports it
  /// (immediately for the already-loaded provider imageBuilder hands us).
  double? _aspect;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(OpticalLogo old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image) _resolve();
  }

  void _resolve() {
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  void _onImage(ImageInfo info, bool _) {
    final width = info.image.width;
    final height = info.image.height;
    info.dispose();
    if (!mounted || width <= 0 || height <= 0) return;
    final aspect = width / height;
    if (aspect != _aspect) setState(() => _aspect = aspect);
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final aspect = _aspect;
    if (aspect == null) return const SizedBox.shrink();
    var height = sqrt(widget.area / aspect);
    var width = height * aspect;
    if (width > widget.maxWidth) {
      width = widget.maxWidth;
      height = width / aspect;
    }
    if (height > widget.maxHeight) {
      height = widget.maxHeight;
      width = height * aspect;
    }
    return Align(
      alignment: widget.alignment,
      child: SizedBox(
        width: width,
        height: height,
        child: Image(
          image: widget.image,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
}
