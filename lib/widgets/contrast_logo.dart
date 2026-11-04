import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// A logo that stays legible on the app's dark grounds.
///
/// Many studio logos (Wikimedia, TMDB) are black marks on a TRANSPARENT
/// background, which vanish on near-black. This inspects the decoded pixels
/// once: when the art has real transparency and its visible pixels are dark,
/// it is drawn white with its alpha kept, so the shape reads the same.
/// Coloured or light logos, and logos on their own solid plate, are left
/// exactly as they are. The verdict is cached per image.
class ContrastLogo extends StatefulWidget {
  const ContrastLogo({
    super.key,
    required this.image,
    this.fit = BoxFit.contain,
    this.alignment = Alignment.center,
  });

  final ImageProvider image;
  final BoxFit fit;
  final AlignmentGeometry alignment;

  @override
  State<ContrastLogo> createState() => _ContrastLogoState();
}

class _ContrastLogoState extends State<ContrastLogo> {
  /// image → "dark mark on transparency" verdict.
  static final Map<Object, bool> _verdicts = <Object, bool>{};

  static const List<double> _white = <double>[
    0, 0, 0, 0, 255, //
    0, 0, 0, 0, 255, //
    0, 0, 0, 0, 255, //
    0, 0, 0, 1, 0,
  ];

  ImageStream? _stream;
  late final ImageStreamListener _listener = ImageStreamListener(
    _onImage,
    onError: (_, _) {},
  );
  bool _invert = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolve();
  }

  @override
  void didUpdateWidget(ContrastLogo old) {
    super.didUpdateWidget(old);
    if (old.image != widget.image) _resolve();
  }

  void _resolve() {
    final cached = _verdicts[widget.image];
    if (cached != null) {
      _invert = cached;
      _stream?.removeListener(_listener);
      _stream = null;
      return;
    }
    final stream = widget.image.resolve(createLocalImageConfiguration(context));
    if (stream.key == _stream?.key) return;
    _stream?.removeListener(_listener);
    _stream = stream..addListener(_listener);
  }

  Future<void> _onImage(ImageInfo info, bool _) async {
    final key = widget.image;
    final image = info.image.clone();
    info.dispose();
    try {
      final verdict = await _isDarkOnTransparent(image);
      _verdicts[key] = verdict;
      if (mounted && widget.image == key && verdict != _invert) {
        setState(() => _invert = verdict);
      }
    } finally {
      image.dispose();
    }
  }

  static Future<bool> _isDarkOnTransparent(ui.Image image) async {
    final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (data == null) return false;
    final bytes = data.buffer.asUint8List();
    final pixels = bytes.length ~/ 4;
    if (pixels == 0) return false;
    // Sample at most ~20k pixels; logos here are small anyway.
    final step = (pixels / 20000).ceil().clamp(1, 1 << 20);
    var sampled = 0, transparent = 0, opaque = 0;
    var luminance = 0.0;
    for (var p = 0; p < pixels; p += step) {
      final i = p * 4;
      sampled++;
      final alpha = bytes[i + 3];
      if (alpha < 32) {
        transparent++;
        continue;
      }
      if (alpha < 160) continue; // anti-aliased edge
      opaque++;
      luminance += (0.2126 * bytes[i] +
              0.7152 * bytes[i + 1] +
              0.0722 * bytes[i + 2]) /
          255;
    }
    if (opaque == 0) return false;
    // Needs real transparency (a logo on its own plate keeps its colours)
    // and dark marks (coloured / light logos already read on dark grounds).
    return transparent / sampled > 0.12 && luminance / opaque < 0.28;
  }

  @override
  void dispose() {
    _stream?.removeListener(_listener);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = Image(
      image: widget.image,
      fit: widget.fit,
      alignment: widget.alignment,
      filterQuality: FilterQuality.medium,
    );
    if (!_invert) return image;
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix(_white),
      child: image,
    );
  }
}
