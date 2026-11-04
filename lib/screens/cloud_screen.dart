import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/profiles/profile_runtime.dart';
import '../services/main_page_bridge.dart';
import '../models/profiles/profile_policy.dart';
import '../services/profiles/profile_policy_guard.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../theme/app_theme_scope.dart';

/// Cloud files entry point. Visible providers open their existing pushed
/// screens; hidden providers can be restored without disconnecting accounts.
/// Connection management lives in Settings and remains profile-gated.
class CloudScreen extends StatefulWidget {
  const CloudScreen({
    super.key,
    this.isTelevision = false,
    @visibleForTesting this.statusLoaderForTesting,
    @visibleForTesting this.restoreHiddenForTesting,
  });

  final bool isTelevision;
  @visibleForTesting
  final Future<List<CloudHubProviderState>> Function()? statusLoaderForTesting;
  @visibleForTesting
  final Future<void> Function(String key)? restoreHiddenForTesting;

  @override
  State<CloudScreen> createState() => _CloudScreenState();
}

enum CloudHubConnectionStatus { ready, hidden, paused, disconnected }

/// Non-sensitive availability snapshot: no credentials or server URLs are
/// exposed to widget rendering or tests.
@immutable
class CloudHubProviderState {
  const CloudHubProviderState(this.key, this.status);

  final String key;
  final CloudHubConnectionStatus status;
}

class _CloudProviderInfo {
  const _CloudProviderInfo(
    this.key,
    this.name,
    this.subtitle,
    this.icon,
    this.color,
  );

  final String key;
  final String name;
  final String subtitle;
  final IconData icon;
  final Color color;
}

class _CloudScreenState extends State<CloudScreen> {
  /// Canonical provider order (mirrors the old per-provider nav order).
  static const List<_CloudProviderInfo> _allProviders = [
    _CloudProviderInfo(
      'realdebrid',
      'Real Debrid',
      'Debrid service',
      Icons.cloud_download_rounded,
      Color(0xFF60A5FA),
    ),
    _CloudProviderInfo(
      'torbox',
      'Torbox',
      'Debrid service',
      Icons.flash_on_rounded,
      Color(0xFFFBBF24),
    ),
    _CloudProviderInfo(
      'pikpak',
      'PikPak',
      'Cloud storage',
      Icons.cloud_circle_rounded,
      Color(0xFF34D399),
    ),
    _CloudProviderInfo(
      'premiumize',
      'Premiumize',
      'Debrid service',
      Icons.workspace_premium_rounded,
      Color(0xFFFB923C),
    ),
    _CloudProviderInfo(
      'alldebrid',
      'AllDebrid',
      'Debrid service',
      Icons.all_inclusive_rounded,
      Color(0xFFEF4444),
    ),
    _CloudProviderInfo(
      'webdav',
      'WebDAV',
      'File server',
      Icons.cloud_sync_rounded,
      Color(0xFF22D3EE),
    ),
  ];

  /// Recomputed on integration/profile changes. Only ready rows may dispatch
  /// file-browsing routes; hidden/paused rows are explanatory, not clickable.
  List<_CloudProviderInfo> _providers = [];
  List<_CloudProviderInfo> _hidden = [];
  List<_CloudProviderInfo> _paused = [];
  List<_CloudProviderInfo> _disconnected = [];
  bool _loading = true;
  bool _denied = false;
  String? _error;
  int _loadEpoch = 0;

  /// Stable per-key focus despite async reordering and visibility changes.
  final Map<String, FocusNode> _nodes = {
    for (final p in _allProviders)
      p.key: FocusNode(debugLabel: 'cloud_provider_${p.key}'),
  };
  final Map<String, FocusNode> _restoreNodes = {
    for (final p in _allProviders)
      p.key: FocusNode(debugLabel: 'cloud_restore_${p.key}'),
  };
  final FocusNode _setupNode = FocusNode(debugLabel: 'cloud_setup');
  final FocusNode _retryNode = FocusNode(debugLabel: 'cloud_retry');

  /// The sidebar requested content focus before the async provider load
  /// finished (nodes didn't exist yet) — re-arm once tiles are built.
  bool _tvFocusPending = false;

  static const int _tabIndex = 16;

  @override
  void initState() {
    super.initState();
    MainPageBridge.addIntegrationListener(_onIntegrationsChanged);
    ProfileRuntime.scope.addListener(_onIntegrationsChanged);
    if (widget.isTelevision) {
      MainPageBridge.registerTvContentFocusHandler(_tabIndex, _focusFirstTile);
    }
    _load();
  }

  @override
  void didUpdateWidget(CloudScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isTelevision != widget.isTelevision) {
      if (oldWidget.isTelevision) {
        MainPageBridge.unregisterTvContentFocusHandler(
          _tabIndex,
          _focusFirstTile,
        );
      } else {
        MainPageBridge.registerTvContentFocusHandler(
          _tabIndex,
          _focusFirstTile,
        );
      }
    }
  }

  @override
  void dispose() {
    _loadEpoch++;
    MainPageBridge.removeIntegrationListener(_onIntegrationsChanged);
    ProfileRuntime.scope.removeListener(_onIntegrationsChanged);
    if (widget.isTelevision) {
      MainPageBridge.unregisterTvContentFocusHandler(
        _tabIndex,
        _focusFirstTile,
      );
    }
    for (final node in [..._nodes.values, ..._restoreNodes.values]) {
      node.dispose();
    }
    _setupNode.dispose();
    _retryNode.dispose();
    super.dispose();
  }

  void _onIntegrationsChanged() => _load();

  Future<void> _load() async {
    final request = ++_loadEpoch;
    if (!ProfilePolicyGuard.allowsSync(ProfileFeature.cloudFiles)) {
      if (mounted) {
        setState(() {
          _denied = true;
          _providers = [];
          _hidden = [];
          _paused = [];
          _disconnected = [];
          _loading = false;
          _error = null;
        });
      }
      return; // No credential or connection-state reads for denied profiles.
    }
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _denied = false;
      });
    }
    try {
      final status =
          await (widget.statusLoaderForTesting?.call() ??
              _computeProviderStates());
      if (!mounted || request != _loadEpoch) return;
      if (!ProfilePolicyGuard.allowsSync(ProfileFeature.cloudFiles)) {
        _load(); // Clear stale cross-profile data without revealing it.
        return;
      }
      final byKey = {for (final s in status) s.key: s.status};
      setState(() {
        _providers = [
          for (final p in _allProviders)
            if (byKey[p.key] == CloudHubConnectionStatus.ready) p,
        ];
        _hidden = [
          for (final p in _allProviders)
            if (byKey[p.key] == CloudHubConnectionStatus.hidden) p,
        ];
        _paused = [
          for (final p in _allProviders)
            if (byKey[p.key] == CloudHubConnectionStatus.paused) p,
        ];
        _disconnected = [
          for (final p in _allProviders)
            if (byKey[p.key] == CloudHubConnectionStatus.disconnected) p,
        ];
        _loading = false;
      });
    } catch (_) {
      if (!mounted || request != _loadEpoch) return;
      setState(() {
        _loading = false;
        _error = 'Connections could not be loaded.';
      });
    }
    if (_tvFocusPending && widget.isTelevision) _focusFirstTile();
    if (widget.isTelevision) _repairFocus();
  }

  /// Matches the shell's existing eligibility checks, with distinct hidden,
  /// paused and unconfigured outcomes instead of discarding all non-ready rows.
  Future<List<CloudHubProviderState>> _computeProviderStates() async {
    final result = <CloudHubProviderState>[];
    void add(
      String key, {
      required bool configured,
      required bool enabled,
      required bool hidden,
    }) {
      result.add(
        CloudHubProviderState(
          key,
          !configured
              ? CloudHubConnectionStatus.disconnected
              : !enabled
              ? CloudHubConnectionStatus.paused
              : hidden
              ? CloudHubConnectionStatus.hidden
              : CloudHubConnectionStatus.ready,
        ),
      );
    }

    final rdEnabled = await StorageService.getRealDebridIntegrationEnabled();
    final rdKey = await StorageService.getApiKey();
    final rdHidden = await StorageService.getRealDebridHiddenFromNav();
    add(
      'realdebrid',
      configured: rdKey?.isNotEmpty ?? false,
      enabled: rdEnabled,
      hidden: rdHidden,
    );

    final tbEnabled = await StorageService.getTorboxIntegrationEnabled();
    final tbKey = await StorageService.getTorboxApiKey();
    final tbHidden = await StorageService.getTorboxHiddenFromNav();
    add(
      'torbox',
      configured: tbKey?.isNotEmpty ?? false,
      enabled: tbEnabled,
      hidden: tbHidden,
    );

    final ppEnabled = await StorageService.getPikPakEnabled();
    final ppHidden = await StorageService.getPikPakHiddenFromNav();
    add(
      'pikpak',
      configured: await StorageService.hasPikPakCredential(),
      enabled: ppEnabled,
      hidden: ppHidden,
    );

    final pmEnabled = await StorageService.getPremiumizeIntegrationEnabled();
    final pmKey = await StorageService.getPremiumizeApiKey();
    final pmHidden = await StorageService.getPremiumizeHiddenFromNav();
    add(
      'premiumize',
      configured: pmKey?.isNotEmpty ?? false,
      enabled: pmEnabled,
      hidden: pmHidden,
    );

    final adEnabled = await StorageService.getAllDebridIntegrationEnabled();
    final adKey = await StorageService.getAllDebridApiKey();
    final adHidden = await StorageService.getAllDebridHiddenFromNav();
    add(
      'alldebrid',
      configured: adKey?.isNotEmpty ?? false,
      enabled: adEnabled,
      hidden: adHidden,
    );

    final webDavEnabled = await StorageService.getWebDavEnabled();
    final webDavServers = await StorageService.getWebDavServers(
      forSettings: false,
    );
    final wdHidden = await StorageService.getWebDavHiddenFromNav();
    add(
      'webdav',
      configured: webDavServers.isNotEmpty,
      enabled: webDavEnabled,
      hidden: wdHidden,
    );
    return result;
  }

  bool get _canManage =>
      ProfilePolicyGuard.allowsSync(ProfileFeature.manageConnections);

  List<FocusNode> _focusOrder() {
    if (_denied) return [];
    if (_loading) return [];
    if (_error != null) return [_retryNode];
    return [
      for (final p in _providers) _nodes[p.key]!,
      if (_canManage)
        for (final p in _hidden) _restoreNodes[p.key]!,
      if (_canManage) _setupNode,
    ];
  }

  void _repairFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final available = _focusOrder();
      if (available.isEmpty) return;
      final current = FocusManager.instance.primaryFocus;
      if (_tvFocusPending ||
          current == null ||
          [
                ..._nodes.values,
                ..._restoreNodes.values,
                _setupNode,
                _retryNode,
              ].contains(current) &&
              !available.contains(current)) {
        _tvFocusPending = false;
        available.first.requestFocus();
      }
    });
  }

  void _focusFirstTile() {
    if (!mounted) return;
    if (_loading) {
      _tvFocusPending = true;
      return;
    }
    _tvFocusPending = true;
    _repairFocus();
  }

  void _openProvider(String key) {
    if (!ProfilePolicyGuard.allowsSync(ProfileFeature.cloudFiles)) {
      _load();
      return;
    }
    if (!_providers.any((p) => p.key == key)) return;
    MainPageBridge.openCloudProvider?.call(key);
  }

  Future<void> _restore(String key) async {
    if (!_canManage ||
        !ProfilePolicyGuard.allowsSync(ProfileFeature.cloudFiles)) {
      return;
    }
    if (!_hidden.any((p) => p.key == key)) return;
    try {
      final override = widget.restoreHiddenForTesting;
      if (override != null) {
        await override(key);
      } else {
        switch (key) {
          case 'realdebrid':
            await StorageService.setRealDebridHiddenFromNav(false);
          case 'torbox':
            await StorageService.setTorboxHiddenFromNav(false);
          case 'pikpak':
            await StorageService.setPikPakHiddenFromNav(false);
          case 'premiumize':
            await StorageService.setPremiumizeHiddenFromNav(false);
          case 'alldebrid':
            await StorageService.setAllDebridHiddenFromNav(false);
          case 'webdav':
            await StorageService.setWebDavHiddenFromNav(false);
          default:
            return;
        }
      }
      if (!mounted || !_canManage) return;
      // This widget is already a registered integration listener. One
      // notification refreshes both the hub and the shell's provider flags.
      MainPageBridge.notifyIntegrationChanged();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not restore this provider. Try again.';
      });
    }
  }

  void _manageConnections() {
    if (_canManage &&
        ProfilePolicyGuard.allowsSync(ProfileFeature.cloudFiles)) {
      MainPageBridge.switchTab?.call(MainTab.settings);
    }
  }

  KeyEventResult _onTileKey(
    FocusNode node,
    KeyEvent event, {
    VoidCallback? activate,
  }) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final order = _focusOrder();
    final index = order.indexOf(node);
    if (index < 0) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      if (index > 0) {
        order[index - 1].requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (index < order.length - 1) {
        order[index + 1].requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      // Left edge → hand focus back to the TV sidebar. Off-TV there's no
      // sidebar to focus, so let the event fall through (don't swallow it).
      final focusSidebar = MainPageBridge.focusTvSidebar;
      if (focusSidebar == null) return KeyEventResult.ignored;
      focusSidebar();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.gameButtonA) {
      activate?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    return Scaffold(
      backgroundColor: app.cloud.bg,
      // All tones derive from the active Cloud theme, including light looks.
      body: DecoratedBox(
        decoration: BoxDecoration(gradient: app.cloud.hubWash),
        child: SafeArea(
          child: _denied
              ? _accessDenied(app)
              : _loading
              ? Center(
                  child: CircularProgressIndicator(color: app.cloud.accent),
                )
              : _error != null
              ? _loadFailed(app)
              : _providerList(app),
        ),
      ),
    );
  }

  Widget _emptyState(AppTheme app) {
    final hasHidden = _hidden.isNotEmpty && _canManage;
    final hasPaused = _paused.isNotEmpty && _canManage;
    final title = hasHidden
        ? 'All available providers are hidden'
        : hasPaused
        ? 'Your connections are paused'
        : 'No connected providers';
    final detail = hasHidden
        ? 'Hidden means removed from Cloud, not disconnected. '
              'Restore a provider below to browse its files.'
        : hasPaused
        ? 'Re-enable a paused connection in Settings to browse files.'
        : 'Connect a provider in Settings to browse your cloud files.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    app.fade(app.cloud.accent, 0.22),
                    app.fade(app.cloud.accent, 0.06),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                shape: BoxShape.circle,
                border: Border.all(color: app.fade(app.cloud.accent, 0.35)),
              ),
              child: Icon(
                Icons.cloud_off_rounded,
                size: 40,
                color: app.cloud.accent,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              title,
              key: const ValueKey('cloud-empty-state'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: app.core.tx,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                height: 1.4,
                color: app.fade(app.core.tx, 0.72),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _accessDenied(AppTheme app) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline_rounded, size: 42, color: app.cloud.accent),
          const SizedBox(height: 18),
          Text(
            'Cloud files unavailable',
            key: const ValueKey('cloud-access-denied'),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: app.core.tx,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            'This profile cannot browse cloud files. Playback through '
            'approved providers is unaffected.',
            textAlign: TextAlign.center,
            style: TextStyle(color: app.fade(app.core.tx, 0.75)),
          ),
        ],
      ),
    ),
  );

  Widget _loadFailed(AppTheme app) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Unable to load Cloud',
            key: const ValueKey('cloud-load-error'),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: app.core.tx,
            ),
          ),
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: app.fade(app.core.tx, 0.75))),
          const SizedBox(height: 24),
          _actionTile(
            app,
            key: 'cloud-retry',
            node: _retryNode,
            title: 'Retry loading',
            subtitle: 'Try reading your connections again',
            icon: Icons.refresh_rounded,
            onTap: _load,
          ),
        ],
      ),
    ),
  );

  Widget _providerList(AppTheme app) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 28, 20, 32),
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(4, 0, 4, 2),
              child: Text(
                'Cloud',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.6,
                  color: app.core.tx,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 4, 20),
              child: Text(
                'Browse connected files or manage your connections',
                style: TextStyle(
                  fontSize: 14.5,
                  color: app.fade(app.core.tx, 0.7),
                ),
              ),
            ),
            if (_providers.isEmpty)
              _emptyState(app)
            else ...[
              _sectionTitle(
                app,
                'Available to browse',
                '${_providers.length} connected',
              ),
            ],
            for (final p in _providers) ...[
              _providerTile(p, app),
              const SizedBox(height: 14),
            ],
            if (_canManage && _hidden.isNotEmpty) ...[
              const SizedBox(height: 14),
              _sectionTitle(
                app,
                'Hidden from Cloud',
                'Still connected · Restore without reconnecting',
              ),
              for (final p in _hidden) ...[
                _actionTile(
                  app,
                  key: 'cloud-restore-${p.key}',
                  node: _restoreNodes[p.key]!,
                  title: 'Restore ${p.name}',
                  subtitle: 'Connected but hidden · Show in Cloud',
                  icon: Icons.visibility_rounded,
                  onTap: () => _restore(p.key),
                ),
                const SizedBox(height: 12),
              ],
            ],
            if (_canManage && _paused.isNotEmpty) ...[
              const SizedBox(height: 14),
              _sectionTitle(
                app,
                'Paused connections',
                'Configured but disabled in Settings',
              ),
              for (final p in _paused)
                Padding(
                  key: ValueKey('cloud-paused-${p.key}'),
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 14),
                  child: Row(
                    children: [
                      Icon(
                        Icons.pause_circle_outline_rounded,
                        color: app.cloud.statusWarning,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '${p.name} · Enable in Settings',
                          style: TextStyle(color: app.fade(app.core.tx, 0.8)),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
            if (_canManage && _disconnected.isNotEmpty) ...[
              const SizedBox(height: 14),
              _sectionTitle(
                app,
                'Not connected',
                'Set up these providers from Settings',
              ),
              Text(
                _disconnected.map((p) => p.name).join(' · '),
                key: const ValueKey('cloud-disconnected-list'),
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: app.fade(app.core.tx, 0.72),
                ),
              ),
            ],
            if (_canManage) ...[
              const SizedBox(height: 24),
              _actionTile(
                app,
                key: 'cloud-manage-connections',
                node: _setupNode,
                title: 'Manage connections',
                subtitle: 'Connect, disconnect, hide, or re-enable providers',
                icon: Icons.settings_rounded,
                onTap: _manageConnections,
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'Hiding removes a provider from Cloud without disconnecting '
              'it. Disconnecting removes account access in Settings.',
              key: const ValueKey('cloud-visibility-explanation'),
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: app.fade(app.core.tx, 0.65),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(AppTheme app, String heading, String detail) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 2, 4, 14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          heading,
          style: TextStyle(
            color: app.core.tx,
            fontWeight: FontWeight.w700,
            fontSize: 17,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          detail,
          style: TextStyle(color: app.fade(app.core.tx, 0.65), fontSize: 12.5),
        ),
      ],
    ),
  );

  Widget _actionTile(
    AppTheme app, {
    required String key,
    required FocusNode node,
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return Focus(
      key: ValueKey(key),
      focusNode: node,
      onKeyEvent: (n, event) => _onTileKey(n, event, activate: onTap),
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return Material(
            color: Colors.transparent,
            child: InkWell(
              canRequestFocus: false,
              borderRadius: app.shape.br(16),
              onTap: onTap,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 140),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: focused
                      ? app.fade(app.cloud.accent, 0.17)
                      : app.fade(app.core.tx, 0.045),
                  borderRadius: app.shape.br(16),
                  border: Border.all(
                    color: focused
                        ? app.cloud.accent
                        : app.fade(app.core.tx, 0.12),
                    width: focused ? 1.6 : 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(icon, color: app.cloud.accent, size: 24),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              color: app.core.tx,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            subtitle,
                            style: TextStyle(
                              color: app.fade(app.core.tx, 0.68),
                              fontSize: 12.5,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: app.fade(app.core.tx, 0.65),
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

  Widget _providerTile(_CloudProviderInfo p, AppTheme app) {
    return Focus(
      key: ValueKey('cloud-provider-${p.key}'),
      focusNode: _nodes[p.key],
      onKeyEvent: (node, event) =>
          _onTileKey(node, event, activate: () => _openProvider(p.key)),
      // Rebuild the tile when its focus state changes so the highlight tracks
      // DPAD focus (Focus.of(context).hasFocus alone doesn't trigger a rebuild).
      onFocusChange: (_) {
        if (mounted) setState(() {});
      },
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return Material(
            color: Colors.transparent,
            child: InkWell(
              // The parent Focus owns keyboard/DPAD focus; keep InkWell out of
              // focus traversal so it doesn't create a competing focus node.
              canRequestFocus: false,
              borderRadius: app.shape.br(18),
              hoverColor: app.fade(app.core.tx, 0.03),
              onTap: () => _openProvider(p.key),
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
                            app.fade(app.cloud.accent, 0.22),
                            app.fade(app.cloud.accent, 0.07),
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
                        ? app.cloud.accent
                        : app.fade(app.core.tx, 0.08),
                    width: focused ? 1.6 : 1,
                  ),
                  boxShadow: focused
                      ? [
                          BoxShadow(
                            color: app.fade(app.cloud.accent, 0.30),
                            blurRadius: 22,
                            spreadRadius: -6,
                          ),
                        ]
                      : null,
                ),
                child: Row(
                  children: [
                    // Soft gradient icon tile in the provider's brand colour.
                    Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            p.color.withValues(alpha: 0.30),
                            p.color.withValues(alpha: 0.12),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: app.shape.br(14),
                        border: Border.all(
                          color: p.color.withValues(alpha: 0.35),
                        ),
                      ),
                      child: Icon(
                        p.icon,
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
                            p.name,
                            style: TextStyle(
                              fontSize: 16.5,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.2,
                              color: app.core.tx,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'Connected · ${p.subtitle}',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: app.fade(app.core.tx, 0.70),
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
