import 'package:flutter/material.dart';

/// Supported external video players for iOS
/// Each player uses URL schemes to launch with a video URL
enum IosExternalPlayer {
  vlc,
  infuse,
  outplayer,
  nplayer,
  playerXtreme,
  vimu,
  customScheme,
}

extension IosExternalPlayerExtension on IosExternalPlayer {
  /// Human-readable display name
  String get displayName {
    switch (this) {
      case IosExternalPlayer.vlc:
        return 'VLC';
      case IosExternalPlayer.infuse:
        return 'Infuse';
      case IosExternalPlayer.outplayer:
        return 'Outplayer';
      case IosExternalPlayer.nplayer:
        return 'nPlayer';
      case IosExternalPlayer.playerXtreme:
        return 'PlayerXtreme';
      case IosExternalPlayer.vimu:
        return 'Vimu';
      case IosExternalPlayer.customScheme:
        return 'Custom URL Scheme';
    }
  }

  /// Description of the player
  String get description {
    switch (this) {
      case IosExternalPlayer.vlc:
        return 'Free, open-source media player';
      case IosExternalPlayer.infuse:
        return 'Premium player with streaming support';
      case IosExternalPlayer.outplayer:
        return 'Feature-rich video player';
      case IosExternalPlayer.nplayer:
        return 'Powerful media player with codec support';
      case IosExternalPlayer.playerXtreme:
        return 'All-format video player';
      case IosExternalPlayer.vimu:
        return 'Simple and clean video player';
      case IosExternalPlayer.customScheme:
        return 'Define your own URL scheme';
    }
  }

  /// Whether the player ships an Apple TV app that registers this same
  /// scheme. The others are iPhone/iPad-only — offering them on tvOS would
  /// be a row that can never launch anything.
  bool get availableOnTvos {
    switch (this) {
      case IosExternalPlayer.vlc:
      case IosExternalPlayer.infuse:
      case IosExternalPlayer.customScheme:
        return true;
      case IosExternalPlayer.outplayer:
      case IosExternalPlayer.nplayer:
      case IosExternalPlayer.playerXtreme:
      case IosExternalPlayer.vimu:
        return false;
    }
  }

  /// URL scheme for checking if app is installed (for canOpenURL)
  /// This is the base scheme without parameters
  String get urlScheme {
    switch (this) {
      case IosExternalPlayer.vlc:
        return 'vlc://';
      case IosExternalPlayer.infuse:
        return 'infuse://';
      case IosExternalPlayer.outplayer:
        return 'outplayer://';
      case IosExternalPlayer.nplayer:
        return 'nplayer://';
      case IosExternalPlayer.playerXtreme:
        return 'playerxtreme://';
      case IosExternalPlayer.vimu:
        return 'vimu://';
      case IosExternalPlayer.customScheme:
        return ''; // User-defined
    }
  }

  /// Build the full URL to launch the player with a video
  ///
  /// Different players have different URL formats:
  /// - VLC: vlc://http://video.url
  /// - Infuse: infuse://x-callback-url/play?url=http://video.url
  /// - Outplayer: outplayer://http://video.url
  /// - nPlayer: nplayer-http://video.url (replaces http:// with nplayer-)
  /// - PlayerXtreme: playerxtreme://http://video.url
  /// - Vimu: vimu://http://video.url
  String buildLaunchUrl(String videoUrl) {
    switch (this) {
      case IosExternalPlayer.vlc:
        // VLC format: vlc://http://example.com/video.mp4
        return 'vlc://$videoUrl';

      case IosExternalPlayer.infuse:
        // Infuse format: infuse://x-callback-url/play?url=<encoded_url>
        final encodedUrl = Uri.encodeComponent(videoUrl);
        return 'infuse://x-callback-url/play?url=$encodedUrl';

      case IosExternalPlayer.outplayer:
        // Outplayer format: outplayer://http://example.com/video.mp4
        return 'outplayer://$videoUrl';

      case IosExternalPlayer.nplayer:
        // nPlayer format: nplayer-http://example.com/video.mp4
        // Prefix the URL with nplayer-
        if (videoUrl.startsWith('https://') || videoUrl.startsWith('http://')) {
          return 'nplayer-$videoUrl';
        }
        return 'nplayer-http://$videoUrl';

      case IosExternalPlayer.playerXtreme:
        // PlayerXtreme format: playerxtreme://http://example.com/video.mp4
        return 'playerxtreme://$videoUrl';

      case IosExternalPlayer.vimu:
        // Vimu format: vimu://http://example.com/video.mp4
        return 'vimu://$videoUrl';

      case IosExternalPlayer.customScheme:
        // Custom scheme - should not be called directly
        // Use buildCustomLaunchUrl instead
        return videoUrl;
    }
  }

  /// Icon representing the player
  IconData get icon {
    switch (this) {
      case IosExternalPlayer.vlc:
        return Icons.play_circle_filled_rounded;
      case IosExternalPlayer.infuse:
        return Icons.smart_display_rounded;
      case IosExternalPlayer.outplayer:
        return Icons.ondemand_video_rounded;
      case IosExternalPlayer.nplayer:
        return Icons.video_library_rounded;
      case IosExternalPlayer.playerXtreme:
        return Icons.videocam_rounded;
      case IosExternalPlayer.vimu:
        return Icons.play_arrow_rounded;
      case IosExternalPlayer.customScheme:
        return Icons.code_rounded;
    }
  }

  /// Storage key value for persistence
  String get storageKey {
    switch (this) {
      case IosExternalPlayer.vlc:
        return 'vlc';
      case IosExternalPlayer.infuse:
        return 'infuse';
      case IosExternalPlayer.outplayer:
        return 'outplayer';
      case IosExternalPlayer.nplayer:
        return 'nplayer';
      case IosExternalPlayer.playerXtreme:
        return 'playerxtreme';
      case IosExternalPlayer.vimu:
        return 'vimu';
      case IosExternalPlayer.customScheme:
        return 'custom_scheme';
    }
  }

  /// Create IosExternalPlayer from storage key
  static IosExternalPlayer fromStorageKey(String key) {
    switch (key) {
      case 'vlc':
        return IosExternalPlayer.vlc;
      case 'infuse':
        return IosExternalPlayer.infuse;
      case 'outplayer':
        return IosExternalPlayer.outplayer;
      case 'nplayer':
        return IosExternalPlayer.nplayer;
      case 'playerxtreme':
        return IosExternalPlayer.playerXtreme;
      case 'vimu':
        return IosExternalPlayer.vimu;
      case 'custom_scheme':
        return IosExternalPlayer.customScheme;
      default:
        return IosExternalPlayer.vlc; // Default to VLC
    }
  }
}

/// Build a custom URL scheme launch URL from a template
/// Template should contain {url} placeholder
/// Example: "myplayer://play?video={url}"
String buildCustomSchemeLaunchUrl(String template, String videoUrl) {
  if (!template.contains('{url}')) {
    // If no placeholder, append the URL
    return '$template$videoUrl';
  }

  // Check if URL should be encoded (if template contains url= or similar)
  final needsEncoding =
      template.contains('url=') ||
      template.contains('={url}') ||
      template.contains('?{url}');

  final urlToInsert = needsEncoding ? Uri.encodeComponent(videoUrl) : videoUrl;
  return template.replaceAll('{url}', urlToInsert);
}

/// Validate a custom URL scheme template
class CustomSchemeValidation {
  final bool isValid;
  final String? errorMessage;

  const CustomSchemeValidation({required this.isValid, this.errorMessage});

  factory CustomSchemeValidation.valid() {
    return const CustomSchemeValidation(isValid: true);
  }

  factory CustomSchemeValidation.invalid(String message) {
    return CustomSchemeValidation(isValid: false, errorMessage: message);
  }
}

CustomSchemeValidation validateCustomScheme(String? scheme) {
  if (scheme == null || scheme.trim().isEmpty) {
    return CustomSchemeValidation.invalid('URL scheme cannot be empty');
  }

  final trimmed = scheme.trim();

  // Must contain a scheme separator
  if (!trimmed.contains('://')) {
    return CustomSchemeValidation.invalid('Must contain :// (e.g., myapp://)');
  }

  // Should not start with http or https (those aren't custom schemes)
  if (trimmed.startsWith('http://') || trimmed.startsWith('https://')) {
    return CustomSchemeValidation.invalid('Cannot use http:// or https://');
  }

  return CustomSchemeValidation.valid();
}
