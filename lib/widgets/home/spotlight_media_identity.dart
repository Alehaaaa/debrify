import 'dart:math' show min;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/debrify_image_cache.dart';
import '../../services/imdb_enrichment_service.dart';
import '../optical_logo.dart';
import 'spotlight_editorial_signals.dart';

/// One media identity for Home, title detail, loading and player. Page-specific
/// actions and expandable detail copy may be injected without recreating the
/// optical logo, metadata hierarchy or synopsis positioning. Episodes live
/// in the metadata row
/// BELOW the logo, never as an isolated top-of-screen label.
///
/// No network metadata lookups are performed here; all labels must be supplied
/// by the current title/episode. A supplied logo is the only image fetched.
class SpotlightMediaIdentity extends StatelessWidget {
  const SpotlightMediaIdentity({
    super.key,
    required this.title,
    this.logoUrl,
    this.imdbId,
    this.imdbEnrichment,
    this.episodeLabel,
    this.ratingLabel,
    this.yearLabel,
    this.runtimeLabel,
    this.certificate,
    this.genreLabel,
    this.description,
    this.scale = 1,
    this.logoScale,
    this.compact = false,
    this.textAlign = TextAlign.left,
    this.kindLabel,
    this.metadataTrailing,
    this.descriptionChild,
    this.afterDescription,
    this.logoWrapper,
  });

  final String title;
  final String? logoUrl;
  final String? imdbId;
  final ImdbEnrichment? imdbEnrichment;
  final String? episodeLabel;
  final String? ratingLabel;
  final String? yearLabel;
  final String? runtimeLabel;
  final String? certificate;
  final String? genreLabel;
  final String? description;
  final double scale;

  /// Optical artwork scale independent of metadata copy. The wide player
  /// should match the detail page's large wordmark without inflating the
  /// episode, rating and synopsis text below it.
  final double? logoScale;
  final bool compact;
  final TextAlign textAlign;
  final String? kindLabel;

  /// Statuses whose state belongs to a particular route/account remain
  /// inside the shared identity's metadata Wrap, never in an external bar.
  final Widget? metadataTrailing;

  /// Detail-only expandable synopsis; the default remains a clamped Text.
  final Widget? descriptionChild;
  final Widget? afterDescription;

  /// Preserves the detail trailer's precise logo hit-test anchor.
  final Widget Function(Widget logo)? logoWrapper;

  static String? _clean(String? value) {
    final trimmed = value?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  /// A badge is shown only for a real, bounded IMDb-scale number. Never
  /// fabricate a 0.0 rating from a missing field or error placeholder.
  static String? validRating(String? raw) {
    return SpotlightEditorialSignals.validRating(raw);
  }

  /// The detail's expandable body and the clamped Home/player/loader body
  /// share this typography, including the same shadow over moving art.
  static TextStyle synopsisStyle({double scale = 1, bool compact = false}) =>
      TextStyle(
        color: Colors.white.withValues(alpha: 0.82),
        fontSize: (compact ? 12.5 : 14) * scale,
        height: 1.42,
        shadows: const [Shadow(color: Colors.black87, blurRadius: 10)],
      );

  @override
  Widget build(BuildContext context) {
    final k = scale.clamp(0.65, 1.8).toDouble();
    final synopsis = _clean(description);
    final row = <Widget>[];
    var hasTextMetadata = false;
    void append(Widget child) {
      if (!hasTextMetadata) {
        row.add(child);
      } else {
        // Keep the separator WITH its value on Wrap's next row. An isolated
        // bullet at the beginning of a 320dp phone line looks disconnected
        // from the Spotlight metadata it belongs to.
        row.add(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 3 * k,
                height: 3 * k,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.42),
                  ),
                ),
              ),
              SizedBox(width: 9 * k),
              child,
            ],
          ),
        );
      }
      hasTextMetadata = true;
    }

    void text(String? label, {Key? key}) {
      final value = _clean(label);
      if (value == null) return;
      append(
        Text(
          value,
          key: key,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.87),
            fontSize: (compact ? 11.5 : 12.5) * k,
            fontWeight: FontWeight.w500,
            shadows: const [Shadow(color: Colors.black87, blurRadius: 8)],
          ),
        ),
      );
    }

    text(kindLabel);
    if (ratingLabel != null || imdbId != null || imdbEnrichment != null) {
      row.add(
        SpotlightEditorialSignals(
          imdbId: imdbId,
          imdbRating: ratingLabel,
          enrichment: imdbEnrichment,
          scale: k,
          compact: compact,
        ),
      );
    }
    text(episodeLabel, key: const ValueKey('spotlight-media-episode'));
    text(yearLabel);
    text(runtimeLabel);
    text(certificate);
    text(genreLabel);
    if (metadataTrailing != null) row.add(metadataTrailing!);

    final centered = textAlign == TextAlign.center;
    final rightAligned = textAlign == TextAlign.right;
    final alignment = centered
        ? Alignment.bottomCenter
        : rightAligned
        ? Alignment.bottomRight
        : Alignment.bottomLeft;
    final logo = SpotlightMediaLogo(
      title: title,
      logoUrl: _clean(logoUrl),
      scale: (logoScale ?? k).clamp(0.65, 2.0).toDouble(),
      alignment: alignment,
    );

    return Column(
      key: const ValueKey('spotlight-media-identity'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: centered
          ? CrossAxisAlignment.center
          : rightAligned
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        logoWrapper?.call(logo) ?? logo,
        if (row.isNotEmpty) ...[
          SizedBox(height: 10 * k),
          Wrap(
            alignment: centered
                ? WrapAlignment.center
                : rightAligned
                ? WrapAlignment.end
                : WrapAlignment.start,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 9 * k,
            runSpacing: 7 * k,
            children: row,
          ),
        ],
        if (synopsis != null || descriptionChild != null) ...[
          SizedBox(height: 12 * k),
          descriptionChild ??
              Text(
                synopsis ?? '',
                key: const ValueKey('spotlight-media-description'),
                maxLines: compact ? 2 : 3,
                textAlign: textAlign,
                overflow: TextOverflow.ellipsis,
                style: synopsisStyle(scale: k, compact: compact),
              ),
        ],
        ?afterDescription,
      ],
    );
  }
}

/// The exact optical logo used by each Spotlight identity, including the
/// title fallback on the first frame and stable art dimensions.
class SpotlightMediaLogo extends StatelessWidget {
  const SpotlightMediaLogo({
    super.key,
    required this.title,
    required this.logoUrl,
    required this.scale,
    this.alignment = Alignment.bottomLeft,
  });

  final String title;
  final String? logoUrl;
  final double scale;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    // These EXACT Home Spotlight constants are deliberately shared:
    // _LogoOrTitle in spotlight_board.dart uses 39px / w800 fallback and
    // OpticalLogo's 480×104 / 19200px² area bounds.
    final name = Text(
      title,
      key: const ValueKey('spotlight-media-fallback-title'),
      maxLines: 2,
      textAlign: alignment == Alignment.bottomCenter
          ? TextAlign.center
          : alignment == Alignment.bottomRight
          ? TextAlign.right
          : TextAlign.left,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 39 * scale,
        height: 1,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.8,
        color: Colors.white,
        shadows: const [Shadow(color: Colors.black87, blurRadius: 12)],
      ),
    );
    if (logoUrl == null) {
      return Align(alignment: alignment, child: name);
    }
    return LayoutBuilder(
      builder: (context, limits) {
        final available = limits.maxWidth.isFinite
            ? limits.maxWidth
            : OpticalLogo.defaultMaxWidth * scale;
        final w = min(OpticalLogo.defaultMaxWidth * scale, available);
        final h = OpticalLogo.defaultMaxHeight * scale;
        return SizedBox(
          key: const ValueKey('spotlight-media-logo-slot'),
          width: w,
          height: h,
          child: CachedNetworkImage(
            key: const ValueKey('spotlight-media-logo'),
            imageUrl: logoUrl!,
            cacheManager: DebrifyImageCache.manager,
            memCacheWidth: 960,
            imageBuilder: (context, image) => Semantics(
              label: title,
              image: true,
              child: OpticalLogo(
                image: image,
                alignment: alignment,
                maxWidth: w,
                maxHeight: h,
                area: OpticalLogo.defaultArea * scale * scale,
              ),
            ),
            // The slot is reserved on day zero so metadata/progress remain
            // stationary when artwork loads. Unlike an empty placeholder, the
            // title stays readable during slow/offline image loading.
            placeholder: (_, _) => Align(
              alignment: alignment,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: alignment,
                child: SizedBox(width: 235 * scale, child: name),
              ),
            ),
            errorWidget: (_, _, _) => Align(
              alignment: alignment,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: alignment,
                child: SizedBox(width: 235 * scale, child: name),
              ),
            ),
          ),
        );
      },
    );
  }
}
