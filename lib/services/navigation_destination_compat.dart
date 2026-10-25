import 'main_page_bridge.dart';
import '../models/profiles/profile_policy.dart';

/// Existing tab numbers remain stable for old deep links and saved settings.
/// Reels (20) remains a standalone, pinnable destination; the other four feed
/// tabs route through Watch while retaining their original numeric aliases.
abstract final class NavigationDestinationCompat {
  static const List<int> phoneDefaults = <int>[
    MainTab.discover,
    MainTab.watch,
    MainTab.cloud,
    MainTab.downloads,
    MainTab.calendar,
    MainTab.addons,
    MainTab.settings,
  ];

  static String? feedForLegacyTab(int index) => switch (index) {
    MainTab.reels => 'reels',
    MainTab.iptv => 'iptv',
    MainTab.youtube => 'youtube',
    MainTab.debrifyTv => 'debrify_tv',
    MainTab.stremioTv => 'stremio_tv',
    _ => null,
  };

  static int? tabForFeed(String key) => switch (key) {
    'reels' => MainTab.reels,
    'iptv' => MainTab.iptv,
    'youtube' => MainTab.youtube,
    'debrify_tv' => MainTab.debrifyTv,
    'stremio_tv' => MainTab.stremioTv,
    _ => null,
  };

  static ProfileFeature? permissionForFeed(String key) => switch (key) {
    'reels' => ProfileFeature.trackersAndDiscovery,
    'iptv' => ProfileFeature.iptv,
    'youtube' => ProfileFeature.youtube,
    'debrify_tv' => ProfileFeature.debrifyTv,
    'stremio_tv' => ProfileFeature.stremioTv,
    _ => null,
  };

  static bool isCollapsedFeedTab(int index) => switch (index) {
    MainTab.iptv ||
    MainTab.youtube ||
    MainTab.debrifyTv ||
    MainTab.stremioTv => true,
    _ => false,
  };

  static String? cloudForLegacyTab(int index) => switch (index) {
    MainTab.realDebrid => 'realdebrid',
    MainTab.torbox => 'torbox',
    MainTab.pikPak => 'pikpak',
    MainTab.webDav => 'webdav',
    MainTab.premiumize => 'premiumize',
    MainTab.allDebrid => 'alldebrid',
    _ => null,
  };

  /// Collapse only the four former TV feed shortcuts, preserving Reels (20).
  /// Keep the chosen count and relative order, filling any resulting
  /// duplicate slots from defaults rather than silently shrinking the bar.
  static List<int> migratePhonePicks(List<int> previous) {
    if (!previous.any(isCollapsedFeedTab)) {
      return List<int>.of(previous);
    }
    final target = previous.length.clamp(0, 3);
    final migrated = <int>[];
    for (final id in previous) {
      final next = isCollapsedFeedTab(id) ? MainTab.watch : id;
      if (next == MainTab.home || migrated.contains(next)) continue;
      if (migrated.length < target) migrated.add(next);
    }
    for (final fallback in phoneDefaults) {
      if (migrated.length >= target) break;
      if (!migrated.contains(fallback)) migrated.add(fallback);
    }
    return migrated;
  }

  /// IPTV is a transient bootstrap tab. Once authorized and covered by its
  /// startup overlay, async nav recalculation must not remove it merely
  /// because its index was consolidated into Watch.
  static bool retainAuthorizedIptvStartup({
    required int selectedTab,
    required bool overlayOpen,
    required bool profileAllowsIptv,
  }) => selectedTab == MainTab.iptv && overlayOpen && profileAllowsIptv;
}
