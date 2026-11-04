import 'dart:convert';

import 'package:flutter/material.dart';

import '../services/main_page_bridge.dart';

/// Stable metadata for a destination that can appear in the TV/desktop
/// sidebar. [id] is the persisted identity; [tabIndex] is the app's existing
/// routing identity and must never be persisted as a visible-list position.
class SidebarDestination {
  final String id;
  final int tabIndex;
  final String defaultLabel;
  final String section;
  final IconData icon;

  const SidebarDestination({
    required this.id,
    required this.tabIndex,
    required this.defaultLabel,
    required this.section,
    required this.icon,
  });
}

/// Every destination that can appear in the Android TV or wide-window
/// sidebar, in the default order shown for new sidebar configurations.
/// Availability is still decided by MainPage's integration/profile policy;
/// this catalog only controls the relative order of destinations that survive
/// that filtering.
const List<SidebarDestination> sidebarDestinations = <SidebarDestination>[
  SidebarDestination(
    id: 'search',
    tabIndex: MainTab.search,
    defaultLabel: 'Search',
    section: 'Main',
    icon: Icons.search_rounded,
  ),
  SidebarDestination(
    id: 'home',
    tabIndex: MainTab.home,
    defaultLabel: 'Home',
    section: 'Main',
    icon: Icons.home_rounded,
  ),
  // Reels remains a separate, pinnable destination rather than a Watch feed.
  SidebarDestination(
    id: 'reels',
    tabIndex: MainTab.reels,
    defaultLabel: 'Reels',
    section: 'Main',
    icon: Icons.slow_motion_video_rounded,
  ),
  SidebarDestination(
    id: 'discover',
    tabIndex: MainTab.discover,
    defaultLabel: 'Explore',
    section: 'Main',
    icon: Icons.explore_rounded,
  ),
  // The four channel/TV feeds are consolidated behind this Watch hub.
  SidebarDestination(
    id: 'watch',
    tabIndex: MainTab.watch,
    defaultLabel: 'Watch',
    section: 'Main',
    icon: Icons.live_tv_rounded,
  ),
  SidebarDestination(
    id: 'calendar',
    tabIndex: MainTab.calendar,
    defaultLabel: 'Calendar',
    section: 'Main',
    icon: Icons.calendar_month_rounded,
  ),
  SidebarDestination(
    id: 'downloads',
    tabIndex: MainTab.downloads,
    defaultLabel: 'Downloads',
    section: 'Main',
    icon: Icons.download_for_offline_rounded,
  ),
  SidebarDestination(
    id: 'cloud',
    tabIndex: MainTab.cloud,
    defaultLabel: 'Cloud',
    section: 'Library',
    icon: Icons.cloud_rounded,
  ),
  SidebarDestination(
    id: 'addons',
    tabIndex: MainTab.addons,
    defaultLabel: 'Addons',
    section: 'Setup',
    icon: Icons.extension_rounded,
  ),
  SidebarDestination(
    id: 'settings',
    tabIndex: MainTab.settings,
    defaultLabel: 'Settings',
    section: 'Setup',
    icon: Icons.settings_rounded,
  ),
];

final Map<String, SidebarDestination> sidebarDestinationById =
    Map<String, SidebarDestination>.unmodifiable(<String, SidebarDestination>{
      for (final destination in sidebarDestinations)
        destination.id: destination,
    });

final Map<int, SidebarDestination> sidebarDestinationByTab =
    Map<int, SidebarDestination>.unmodifiable(<int, SidebarDestination>{
      for (final destination in sidebarDestinations)
        destination.tabIndex: destination,
    });

/// Profile-scoped customization shared by Android TV and desktop/tablet
/// sidebars. Integration settings and profile policy still gate availability;
/// this configuration can additionally hide optional destinations.
class SidebarConfiguration {
  static const int schemaVersion = 1;
  static const int maxLabelRunes = 24;
  static const int maxSerializedBytes = 4096;

  // The v1 catalog in HEAD had these four separate destinations. Retain their
  // exact stable IDs as recognized *stored* preferences: existing users may
  // have named or hidden individual feeds. The new catalog shows one Watch
  // entry, but round-tripping settings must not erase those choices. Reels is
  // still a standalone destination in sidebarDestinations.
  static const Map<String, String> _retiredFeedDefaultLabels = {
    'iptv': 'IPTV',
    'youtube': 'YouTube',
    'debrify_tv': 'Nextup TV',
    'stremio_tv': 'Stremio TV',
  };

  static bool _isStoredDestinationId(String id) =>
      sidebarDestinationById.containsKey(id) ||
      _retiredFeedDefaultLabels.containsKey(id);

  final List<String> order;
  final Map<String, String> labels;
  final Set<String> hiddenDestinationIds;

  SidebarConfiguration({
    required Iterable<String> order,
    Map<String, String> labels = const <String, String>{},
    Iterable<String> hiddenDestinationIds = const <String>{},
  }) : order = List<String>.unmodifiable(_normalizeOrder(order)),
       labels = Map<String, String>.unmodifiable(_normalizeLabels(labels)),
       hiddenDestinationIds = Set<String>.unmodifiable(
         _normalizeHiddenDestinationIds(hiddenDestinationIds),
       );

  factory SidebarConfiguration.defaults() => SidebarConfiguration(
    order: sidebarDestinations.map((destination) => destination.id),
  );

  /// Parses a stored value. Invalid or future-version data returns null so a
  /// caller can fall back to defaults without partially applying corruption.
  static SidebarConfiguration? tryDecode(String raw) {
    if (utf8.encode(raw).length > maxSerializedBytes) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != schemaVersion) {
        return null;
      }
      final rawOrder = decoded['order'];
      final rawLabels = decoded['labels'];
      if (rawOrder is! List || rawLabels is! Map) return null;
      final rawHidden = decoded['hidden'];
      if (rawHidden != null && rawHidden is! List) return null;

      final storedOrder = <String>[];
      final seen = <String>{};
      for (final value in rawOrder) {
        if (value is! String ||
            !_isStoredDestinationId(value) ||
            !seen.add(value)) {
          return null;
        }
        storedOrder.add(value);
      }

      final labels = <String, String>{};
      for (final entry in rawLabels.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is! String ||
            value is! String ||
            !_isStoredDestinationId(key)) {
          return null;
        }
        final normalized = normalizeLabel(value);
        if (normalized == null || normalized != value) return null;
        labels[key] = value;
      }
      final hidden = <String>[];
      for (final value in rawHidden ?? const <dynamic>[]) {
        if (value is! String || !_isStoredDestinationId(value)) {
          return null;
        }
        hidden.add(value);
      }

      // A previously saved v1 order can contain several of the four feed IDs.
      // Collapse at the FIRST feed's position, retaining all other relative
      // positions; an explicitly ordered Watch entry from a newer v1 save wins
      // over old feed positions. Reels keeps its own position either way.
      final hasWatch = storedOrder.contains('watch');
      final order = <String>[];
      var addedWatch = false;
      for (final id in storedOrder) {
        if (_retiredFeedDefaultLabels.containsKey(id)) {
          if (!hasWatch && !addedWatch) {
            order.add('watch');
            addedWatch = true;
          }
        } else {
          order.add(id);
        }
      }

      if (addedWatch) {
        // Prefer the custom name of the first still-visible feed, then the
        // first hidden one. An explicit Watch label always takes precedence.
        // Keep original per-feed labels as latent metadata in case the user
        // later restores a standalone feed entry.
        if (!labels.containsKey('watch')) {
          final feeds = storedOrder.where(
            _retiredFeedDefaultLabels.containsKey,
          );
          final candidates = [
            ...feeds.where((id) => !hidden.contains(id)),
            ...feeds.where(hidden.contains),
          ];
          for (final id in candidates) {
            final label = labels[id];
            if (label != null && label != _retiredFeedDefaultLabels[id]) {
              labels['watch'] = label;
              break;
            }
          }
        }

        // Hiding only one old feed must never make the whole Watch hub vanish.
        // All four explicitly hidden means the user intended no channel/TV
        // feeds in the navigation. Availability/disabled integrations are
        // handled by MainPage; they cannot be inferred from sidebar settings.
        if (_retiredFeedDefaultLabels.keys.every(hidden.contains)) {
          hidden.add('watch');
        }
      }
      return SidebarConfiguration(
        order: order,
        labels: labels,
        hiddenDestinationIds: hidden,
      );
    } on FormatException {
      return null;
    }
  }

  String encode() => jsonEncode(<String, Object>{
    'version': schemaVersion,
    'order': order,
    'labels': labels,
    if (hiddenDestinationIds.isNotEmpty) 'hidden': hiddenDestinationIds.toList()..sort(),
  });

  SidebarConfiguration copyWith({
    Iterable<String>? order,
    Map<String, String>? labels,
    Iterable<String>? hiddenDestinationIds,
  }) => SidebarConfiguration(
    order: order ?? this.order,
    labels: labels ?? this.labels,
    hiddenDestinationIds: hiddenDestinationIds ?? this.hiddenDestinationIds,
  );

  bool isVisible(String id) => !hiddenDestinationIds.contains(id);

  String labelForId(String id) =>
      labels[id] ?? sidebarDestinationById[id]?.defaultLabel ?? id;

  String labelForTab(int tabIndex, String fallback) {
    final destination = sidebarDestinationByTab[tabIndex];
    return destination == null ? fallback : labelForId(destination.id);
  }

  /// Drops hidden destinations but keeps the incoming order. Phone navigation
  /// uses this: it honours visibility without adopting the sidebar ordering.
  List<int> filterHiddenTabs(Iterable<int> visibleTabs) => [
    for (final tabIndex in visibleTabs)
      if (isVisible(sidebarDestinationByTab[tabIndex]?.id ?? '')) tabIndex,
  ];

  /// Applies the saved ranking only after MainPage has decided which tabs are
  /// visible. Unknown future tabs stay reachable and retain their incoming
  /// relative order at the end until the catalog learns about them.
  List<int> orderVisibleTabs(Iterable<int> visibleTabs) {
    final visible = filterHiddenTabs(visibleTabs);
    final rank = <int, int>{};
    for (var i = 0; i < order.length; i++) {
      final destination = sidebarDestinationById[order[i]];
      if (destination != null) rank[destination.tabIndex] = i;
    }
    final incomingRank = <int, int>{
      for (var i = 0; i < visible.length; i++) visible[i]: i,
    };
    visible.sort((a, b) {
      final aRank = rank[a];
      final bRank = rank[b];
      if (aRank != null && bRank != null) return aRank.compareTo(bRank);
      if (aRank != null) return -1;
      if (bRank != null) return 1;
      return incomingRank[a]!.compareTo(incomingRank[b]!);
    });
    return visible;
  }

  bool get isDefault {
    if (labels.isNotEmpty ||
        hiddenDestinationIds.isNotEmpty ||
        order.length != sidebarDestinations.length) {
      return false;
    }
    for (var i = 0; i < order.length; i++) {
      if (order[i] != sidebarDestinations[i].id) return false;
    }
    return true;
  }

  static String? normalizeLabel(String raw) {
    final normalized = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (normalized.isEmpty ||
        normalized.runes.length > maxLabelRunes ||
        normalized.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
      return null;
    }
    return normalized;
  }

  static List<String> _normalizeOrder(Iterable<String> raw) {
    final result = <String>[];
    final seen = <String>{};
    for (final id in raw) {
      if (sidebarDestinationById.containsKey(id) && seen.add(id)) {
        result.add(id);
      }
    }
    for (final destination in sidebarDestinations) {
      if (seen.add(destination.id)) result.add(destination.id);
    }
    return result;
  }

  static Map<String, String> _normalizeLabels(Map<String, String> raw) {
    final result = <String, String>{};
    for (final entry in raw.entries) {
      final destination = sidebarDestinationById[entry.key];
      final label = normalizeLabel(entry.value);
      final defaultLabel =
          destination?.defaultLabel ?? _retiredFeedDefaultLabels[entry.key];
      if (defaultLabel == null ||
          label == null ||
          label == defaultLabel) {
        continue;
      }
      result[entry.key] = label;
    }
    return result;
  }

  static Set<String> _normalizeHiddenDestinationIds(Iterable<String> raw) => {
    for (final id in raw)
      if (_isStoredDestinationId(id) &&
          id != 'home' &&
          id != 'settings')
        id,
  };
}
