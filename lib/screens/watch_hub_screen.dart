import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/profiles/profile_policy.dart';
import '../services/main_page_bridge.dart';
import '../services/profiles/profile_policy_guard.dart';
import '../theme/app_theme.dart';
import '../theme/app_theme_scope.dart';

/// Watch groups short clips, live TV and video channels in one hub. Clips can
/// also be pinned independently in navigation. Every allowed destination opens
/// through [MainPageBridge.openFeed], preserving its screen and Back behavior.
class WatchHubScreen extends StatefulWidget {
  const WatchHubScreen({super.key, this.isTelevision = false});

  final bool isTelevision;

  @override
  State<WatchHubScreen> createState() => _WatchHubScreenState();
}

class _FeedInfo {
  const _FeedInfo(
    this.key,
    this.name,
    this.subtitle,
    this.icon,
    this.color,
    this.feature,
  );

  final String key;
  final String name;
  final String subtitle;
  final IconData icon;
  final Color color;
  final ProfileFeature feature;
}

class _WatchHubScreenState extends State<WatchHubScreen> {
  /// The feed keys are shared with main.dart's pushed-route dispatcher.
  /// Clips retains its own short-form identity and can be pinned separately.
  static const List<_FeedInfo> _feeds = [
    _FeedInfo(
      'reels',
      'Clips',
      'Short videos & trailers',
      Icons.slow_motion_video_rounded,
      Color(0xFFAE8CFF),
      ProfileFeature.trackersAndDiscovery,
    ),
    _FeedInfo(
      'iptv',
      'IPTV',
      'Your live TV channels',
      Icons.live_tv_rounded,
      Color(0xFF60A5FA),
      ProfileFeature.iptv,
    ),
    _FeedInfo(
      'youtube',
      'YouTube',
      'Videos & channels',
      Icons.ondemand_video_rounded,
      Color(0xFFEF4444),
      ProfileFeature.youtube,
    ),
    _FeedInfo(
      'debrify_tv',
      'Nextup TV',
      'Keyword channels',
      Icons.tv_rounded,
      Color(0xFFFBBF24),
      ProfileFeature.debrifyTv,
    ),
    _FeedInfo(
      'stremio_tv',
      'Stremio TV',
      'Random-play channels',
      Icons.smart_display_rounded,
      Color(0xFF34D399),
      ProfileFeature.stremioTv,
    ),
  ];

  /// Stable feed identities keep DPAD focus with the same tile when another
  /// feed becomes unavailable; visible positions can change per profile.
  final Map<String, FocusNode> _nodes = {
    for (final feed in _feeds)
      feed.key: FocusNode(debugLabel: 'watch_tile_${feed.key}'),
  };
  final FocusNode _emptyFocusNode = FocusNode(debugLabel: 'watch_empty');
  String? _focusedFeedKey;

  static const int _tabIndex = MainTab.watch;

  @override
  void initState() {
    super.initState();
    if (widget.isTelevision) {
      MainPageBridge.registerTvContentFocusHandler(_tabIndex, _focusFirstTile);
    }
  }

  @override
  void dispose() {
    if (widget.isTelevision) {
      MainPageBridge.unregisterTvContentFocusHandler(
        _tabIndex,
        _focusFirstTile,
      );
    }
    for (final n in _nodes.values) {
      n.dispose();
    }
    _emptyFocusNode.dispose();
    super.dispose();
  }

  List<_FeedInfo> _visibleFeeds() => [
    for (final feed in _feeds)
      if (ProfilePolicyGuard.allowsSync(feed.feature)) feed,
  ];

  void _focusFirstTile() {
    if (!mounted) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final visible = _visibleFeeds();
      if (visible.isEmpty) {
        _emptyFocusNode.requestFocus();
      } else {
        _nodes[visible.first.key]?.requestFocus();
      }
    });
  }

  void _openFeed(_FeedInfo feed) {
    // A profile can change after the tile was built, before an input event.
    // Check again at the interaction boundary as well as when rendering.
    if (!ProfilePolicyGuard.allowsSync(feed.feature)) return;
    MainPageBridge.openFeed?.call(feed.key);
  }

  KeyEventResult _onTileKey(
    KeyEvent event,
    int index,
    List<_FeedInfo> visibleFeeds,
  ) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      if (index > 0) {
        _nodes[visibleFeeds[index - 1].key]?.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (index < visibleFeeds.length - 1) {
        _nodes[visibleFeeds[index + 1].key]?.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      final focusSidebar = MainPageBridge.focusTvSidebar;
      if (focusSidebar == null) return KeyEventResult.ignored;
      focusSidebar();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA) {
      _openFeed(visibleFeeds[index]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    final visibleFeeds = _visibleFeeds();
    // If a policy change removes the focused tile, move focus to another
    // allowed destination (or the empty-state focus target) after the rebuild.
    if (widget.isTelevision &&
        _focusedFeedKey != null &&
        !visibleFeeds.any((feed) => feed.key == _focusedFeedKey)) {
      _focusedFeedKey = null;
      _focusFirstTile();
    }
    return Scaffold(
      backgroundColor: app.core.ground,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 28, 20, 32),
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(4, 0, 4, 2),
                  child: Text(
                    'Watch',
                    style: TextStyle(
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.6,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 20),
                  child: Text(
                    'Pick something to lean back and watch',
                    style: TextStyle(
                      fontSize: 14.5,
                      color: app.fade(app.core.tx, 0.5),
                    ),
                  ),
                ),
                if (visibleFeeds.isEmpty)
                  Focus(
                    focusNode: _emptyFocusNode,
                    onKeyEvent: (_, event) {
                      if (event is KeyDownEvent &&
                          event.logicalKey == LogicalKeyboardKey.arrowLeft) {
                        final focusSidebar = MainPageBridge.focusTvSidebar;
                        if (focusSidebar != null) {
                          focusSidebar();
                          return KeyEventResult.handled;
                        }
                      }
                      return KeyEventResult.ignored;
                    },
                    child: const Padding(
                      padding: EdgeInsets.symmetric(
                        horizontal: 4,
                        vertical: 16,
                      ),
                      child: Text(
                        'No watch feeds are available for this profile.',
                        key: ValueKey('watch-empty-state'),
                      ),
                    ),
                  ),
                for (var i = 0; i < visibleFeeds.length; i++) ...[
                  _feedTile(visibleFeeds[i], i, visibleFeeds, app),
                  const SizedBox(height: 14),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _feedTile(
    _FeedInfo f,
    int index,
    List<_FeedInfo> visibleFeeds,
    AppTheme app,
  ) {
    return Focus(
      key: ValueKey('watch-feed-${f.key}'),
      focusNode: _nodes[f.key],
      onKeyEvent: (node, event) => _onTileKey(event, index, visibleFeeds),
      onFocusChange: (focused) {
        if (focused) {
          _focusedFeedKey = f.key;
        } else if (_focusedFeedKey == f.key) {
          _focusedFeedKey = null;
        }
        if (mounted) setState(() {});
      },
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return Material(
            color: Colors.transparent,
            child: InkWell(
              canRequestFocus: false,
              borderRadius: app.shape.br(18),
              hoverColor: app.fade(app.core.tx, 0.03),
              onTap: () => _openFeed(f),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 15,
                ),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: focused
                        ? [
                            app.fade(app.core.accent, 0.22),
                            app.fade(app.core.accent, 0.07),
                          ]
                        : [
                            app.fade(app.core.tx, 0.055),
                            app.fade(app.core.tx, 0.02),
                          ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: app.shape.br(18),
                  border: Border.all(
                    color: focused
                        ? app.core.accent
                        : app.fade(app.core.tx, 0.08),
                    width: focused ? 1.6 : 1,
                  ),
                  boxShadow: focused
                      ? [
                          BoxShadow(
                            color: app.fade(app.core.accent, 0.30),
                            blurRadius: 22,
                            spreadRadius: -6,
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  children: [
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            f.color.withValues(alpha: 0.30),
                            f.color.withValues(alpha: 0.12),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: app.shape.br(14),
                        border: Border.all(
                          color: f.color.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Icon(
                        f.icon,
                        color: app.fade(app.core.tx, 0.92),
                        size: 25,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            f.name,
                            style: const TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            f.subtitle,
                            style: TextStyle(
                              fontSize: 12.5,
                              color: app.fade(app.core.tx, 0.45),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: app.fade(app.core.tx, focused ? 0.7 : 0.32),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
