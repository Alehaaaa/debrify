import '../../services/webdav_protocol_client.dart';
import '../../services/webdav_sync/webdav_sync_versions.dart';
import 'profile_backup_flows.dart';
import '../../services/webdav_sync/webdav_saved_syncs.dart';
import '../../services/webdav_sync/webdav_log_upload.dart';
import '../../services/webdav_sync/webdav_sync_binding_store.dart';
import '../../services/profiles/profile_preferences.dart';
import '../../services/webdav_sync/webdav_sync_device_removal.dart';
import 'widgets/sync_device_tile.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../models/webdav_item.dart';
import '../../services/analytics_service.dart';
import '../../services/webdav_sync/webdav_sync_clock.dart';
import '../../services/webdav_sync/webdav_sync_engine.dart';
import '../../services/webdav_sync/webdav_sync_feature.dart';
import '../../services/webdav_sync/webdav_sync_connect_controller.dart';
import '../../services/webdav_sync/webdav_sync_models.dart';
import '../../services/webdav_sync/webdav_sync_runtime.dart';
import '../../services/webdav_sync/webdav_sync_scheduler.dart';
import '../../services/webdav_sync/webdav_sync_setup_authorization.dart';
import '../../services/webdav_sync/webdav_sync_setup_service.dart';
import '../../utils/platform_util.dart';
import '../../utils/tv_keys.dart';
import '../../widgets/tv_text_field.dart';
import '../../widgets/webdav_sync/webdav_foreground_sync.dart';
import '../webdav_sync/webdav_sync_login_screen.dart';
import 'widgets/settings_widgets.dart';

class SyncAndMigratePage extends StatefulWidget {
  const SyncAndMigratePage({
    super.key,
    this.syncService,
    this.syncAuthorization,
    this.syncActivation,
    this.syncFeatureEnabled,
    this.launchSyncLogin,
    this.loadSyncVersions,
  });

  final Future<List<WebDavSyncVersion>> Function(WebDavSyncFolderExisting)?
  loadSyncVersions;
  final WebDavSyncSetupService? syncService;
  final WebDavSyncSetupAuthorization? syncAuthorization;
  final WebDavSyncActivationController? syncActivation;
  final bool? syncFeatureEnabled;
  final Future<WebDavSyncLoginCredentials?> Function(
    BuildContext context,
    WebDavSyncConnectController controller,
  )?
  launchSyncLogin;

  @override
  State<SyncAndMigratePage> createState() => _SyncAndMigratePageState();
}

class _SyncAndMigratePageState extends State<SyncAndMigratePage>
    with WidgetsBindingObserver {
  // Keep the bundled QR code in sync with this URL.
  static const _setupGuideUrl = 'https://debrify.tv/guides/webdav-sync/';

  late final WebDavSyncSetupService _syncService;
  late final WebDavSyncSetupAuthorization _syncAuthorization;
  late final WebDavSyncConnectController _syncConnectController;
  WebDavSyncActivationController? _syncActivation;
  WebDavSyncBinding? _syncBinding;
  WebDavSyncRuntimeStatus? _runtimeStatus;
  String? _syncStateMessage;
  bool _syncBusy = false;
  final _savedSyncStore = WebDavSavedSyncs();
  List<WebDavSavedSync> _savedSyncs = [];
  String? _activeSavedSyncId;

  bool _logUploadEnabled = false;
  bool _logSettingsBusy = false;
  bool _logUploading = false;
  String? _logBindingId;
  int _logSettingRevision = 0;
  bool _logoutPending = false;
  bool _deviceRemoved = false;
  Timer? _statusTimer;
  Future<void>? _statusLoading;
  bool _statusReadFailed = false;
  bool _tvSyncLaunching = false;
  bool _guideOpen = false;
  _DebrifyTvSyncOperation? _tvSyncOperation;
  WebDavSyncTvManualAvailability _tvManualAvailability =
      WebDavSyncTvManualAvailability.inactive;

  bool get _syncFeatureEnabled =>
      widget.syncFeatureEnabled ?? WebDavSyncFeature.enabled;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncService = widget.syncService ?? WebDavSyncSetupService();
    _syncAuthorization =
        widget.syncAuthorization ?? const ProfileWebDavSyncSetupAuthorization();
    // A custom setup service in widget tests intentionally exercises the M3
    // read-only boundary. Production owns the integrated M5 activation flow.
    _syncActivation =
        widget.syncActivation ??
        (widget.syncService == null ? WebDavSyncRuntime.instance : null);
    _syncConnectController = createWebDavSyncConnectController(
      setupService: _syncService,
      authorization: _syncAuthorization,
      activation: _syncActivation,
    );
    AnalyticsService.screenView('sync_and_migrate');
    if (_syncFeatureEnabled) {
      _loadSyncState();
      unawaited(_loadLogUploadSetting());
      // Also observe background completion and expiring platform gates while
      // the page remains open. Coalesce reads so a slow cycle never queues
      // an unbounded number of status operations.
      _statusTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        if (!_syncBusy) unawaited(_loadActiveSyncState());
      });
    }
  }

  Future<void> _loadLogUploadSetting() async {
    final revision = ++_logSettingRevision;
    final bindingId = _syncBinding?.id;
    try {
      final enabled = await WebDavLogUpload.instance.isEnabled();
      if (mounted &&
          revision == _logSettingRevision &&
          bindingId == _syncBinding?.id) {
        setState(() {
          _logUploadEnabled = enabled;
          _logBindingId = bindingId;
        });
      }
    } catch (_) {}
  }

  Future<void> _setLogUpload(bool enabled) async {
    if (_logSettingsBusy || _syncBusy || _logoutPending) return;
    setState(() => _logSettingsBusy = true);
    try {
      await _syncAuthorization.requireAdmin();
      await WebDavLogUpload.instance.setEnabled(enabled);
      await _loadLogUploadSetting();
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _logSettingsBusy = false);
    }
  }

  Future<void> _uploadLogsNow() async {
    if (_logUploading) return;
    setState(() => _logUploading = true);
    try {
      await _syncAuthorization.requireAdmin();
      final result = await WebDavLogUpload.instance.upload();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result == WebDavLogUploadResult.uploaded
                ? 'Diagnostic logs uploaded.'
                : result == WebDavLogUploadResult.busy
                ? 'A log upload is already running.'
                : 'Logs could not be uploaded. They remain on this device.',
          ),
        ),
      );
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _logUploading = false);
    }
  }

  @override
  void dispose() {
    _statusTimer?.cancel();
    _tvSyncOperation?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_syncFeatureEnabled && state == AppLifecycleState.resumed) {
      unawaited(_reloadSyncAfterForeground());
    }
  }

  Future<void> _reloadSyncAfterForeground() async {
    // Let the runtime's foreground callback enqueue any first-join promotion
    // before status enters the same serialized runtime operation path.
    await Future<void>.delayed(Duration.zero);
    if (mounted) await _loadActiveSyncState();
  }

  Future<void> _loadSyncState() async {
    try {
      final snapshot = await _syncService.store.load();
      final removed =
          (await DevicePreferences.instance()).getBool(
            WebDavSyncBindingStore.deviceRemovedNoticeKey,
          ) ==
          true;
      if (!mounted) return;
      setState(() {
        _syncBinding = snapshot.stagedBinding ?? snapshot.activeBinding;
        _logoutPending = WebDavSyncBindingStore.logoutPending(snapshot);
        _deviceRemoved = removed && _syncBinding == null;
      });
      unawaited(_loadSavedSyncs());
      unawaited(_loadActiveSyncState());
    } catch (error) {
      if (!mounted) return;
      _showError(error);
    }
  }

  WebDavSyncManagementController? get _management =>
      _syncActivation is WebDavSyncManagementController
      ? _syncActivation as WebDavSyncManagementController
      : null;

  WebDavSyncTvManualController? get _tvManualController =>
      _syncActivation is WebDavSyncTvManualController
      ? _syncActivation as WebDavSyncTvManualController
      : null;

  Future<void> _loadActiveSyncState() {
    final pending = _statusLoading;
    if (pending != null) return pending;
    late final Future<void> started;
    started = _readActiveSyncState().whenComplete(() {
      if (identical(_statusLoading, started)) _statusLoading = null;
    });
    _statusLoading = started;
    return started;
  }

  Future<void> _readActiveSyncState() async {
    final management = _management;
    if (management == null) return;
    try {
      final status = await management.status();
      final tvAvailability =
          await _tvManualController?.tvManualAvailability() ??
          WebDavSyncTvManualAvailability.inactive;
      final snapshot = await _syncService.store.load();
      final removed =
          (await DevicePreferences.instance()).getBool(
            WebDavSyncBindingStore.deviceRemovedNoticeKey,
          ) ==
          true;
      if (status.localStateMissing) {
        if (!mounted) return;
        setState(() {
          _syncBinding = snapshot.stagedBinding ?? snapshot.activeBinding;
          _logoutPending = WebDavSyncBindingStore.logoutPending(snapshot);
          _runtimeStatus = status;
          _statusReadFailed = false;
          if (_logBindingId != _syncBinding?.id) {
            unawaited(_loadLogUploadSetting());
          }
          _tvManualAvailability = tvAvailability;
          _syncStateMessage =
              'Local sync state was cleared. Re-enter your WebDAV password '
              'to reconnect safely.';
        });
        return;
      }
      if (!mounted) return;
      setState(() {
        _syncBinding = snapshot.stagedBinding ?? snapshot.activeBinding;
        _logoutPending = WebDavSyncBindingStore.logoutPending(snapshot);
        _runtimeStatus = status;
        _statusReadFailed = false;
        if (_logBindingId != _syncBinding?.id) {
          unawaited(_loadLogUploadSetting());
        }
        _tvManualAvailability = tvAvailability;
        _deviceRemoved = removed && _syncBinding == null;
        _syncStateMessage = status.adminPruneBlocked
            ? 'Profile cleanup is pending for ${status.pruneBlockingProfiles.join(', ')}; activity sync continues'
            : status.statusHint;
      });
    } catch (_) {
      // Active sync remains usable offline; manual Sync now surfaces errors.
      if (mounted) setState(() => _statusReadFailed = true);
    }
  }

  Future<void> _openSetupGuide() async {
    if (_guideOpen) return;
    _guideOpen = true;
    try {
      if (!PlatformUtil.isTelevision) {
        try {
          if (await launchUrl(
            Uri.parse(_setupGuideUrl),
            mode: LaunchMode.externalApplication,
          )) {
            return;
          }
        } on PlatformException {
          // The readable link and QR code also work without a browser.
        } on MissingPluginException {
          // Some platforms do not provide a URL launcher.
        }
      }
      if (!mounted) return;
      await showSettingsDialog<void>(
        context: context,
        builder: (dialogContext) => TvHeldKeyGuard(
          child: AlertDialog(
            title: const Text('WebDAV Sync setup guide'),
            scrollable: true,
            content: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Scan with your phone or open the link below for '
                    'Koofr setup, app passwords and connecting your devices.',
                  ),
                  const SizedBox(height: 20),
                  Image.asset(
                    'assets/images/webdav_sync_guide_qr.png',
                    width: 200,
                    height: 200,
                    filterQuality: FilterQuality.none,
                    semanticLabel: 'QR code for the WebDAV Sync setup guide',
                  ),
                  const SizedBox(height: 16),
                  if (PlatformUtil.isTelevision)
                    const Text(_setupGuideUrl, textAlign: TextAlign.center)
                  else
                    const SelectableText(
                      _setupGuideUrl,
                      textAlign: TextAlign.center,
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                autofocus: true,
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        ),
      );
    } finally {
      _guideOpen = false;
    }
  }

  Future<void> _configureSync({WebDavSavedSync? saved}) async {
    if (_syncBusy) return;
    if (_logoutPending && !await _forgetConnection()) return;
    if (!mounted) return;
    setState(() => _syncBusy = true);
    final reconfiguration =
        _syncActivation is WebDavSyncReconfigurationController
        ? _syncActivation as WebDavSyncReconfigurationController
        : null;
    var didPause = false;
    try {
      await _syncAuthorization.requireAdmin();
      if (reconfiguration != null) {
        reconfiguration.pauseForReconfiguration();
        didPause = true;
      }
      if (!mounted) return;
      final reconnectBinding =
          saved == null && _syncBinding?.requiresStateReconnect == true
          ? _syncBinding
          : null;
      final reconnectUsername = reconnectBinding == null
          ? null
          : (await _syncService.store.readSecrets(reconnectBinding)).username;
      if (!mounted) return;
      WebDavSyncLoginCredentials? credentials = saved?.credentials;
      if (credentials == null) {
        if (!mounted) return;
        credentials = widget.launchSyncLogin != null
            ? await widget.launchSyncLogin!(context, _syncConnectController)
            : await Navigator.of(context).push<WebDavSyncLoginCredentials>(
                MaterialPageRoute(
                  builder: (_) => WebDavSyncLoginScreen(
                    connectController: _syncConnectController,
                    repairBinding: reconnectBinding,
                    initialUsername: reconnectUsername,
                  ),
                ),
              );
      }
      if (!mounted || credentials == null) return;
      final selectedCredentials = credentials;
      final current = _syncBinding;
      if (current != null && current.lifecycle == WebDavSyncLifecycle.active) {
        final secrets = await _syncService.store.readSecrets(current);
        final currentLogin = WebDavSyncLoginCredentials(
          endpoint: current.location.endpoint,
          username: secrets.username,
          password: secrets.password,
          serverName: current.location.serverName,
        );
        await _rememberSync(currentLogin);
        final targetLocation = WebDavSyncFolderLocation.fromConfig(
          credentials.toConfig(),
          WebDavSyncConnectController.folderPath,
        );
        // The existing binding identity is endpoint-based. Different users on
        // one provider must leave that binding before adopting another root.
        if (targetLocation.fingerprint == current.id &&
            secrets.username != credentials.username) {
          await _syncConnectController.inspect(credentials);
          if (!mounted) return;
          final confirmed = await showSettingsDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Switch sync account?'),
              content: const Text(
                'Disconnect the current account before connecting this saved login. Your current login remains in Saved syncs. You will be asked before replacing local data.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('Switch account'),
                ),
              ],
            ),
          );
          if (confirmed != true) return;
          final logout = _logoutController;
          if (logout == null) {
            throw StateError('Account switching is unavailable');
          }
          await logout.logout();
        }
      }
      if (!mounted) return;
      final outcome = await runWebDavForegroundSync(
        context,
        stage: 'Preparing WebDAV sync…',
        progressLimit: null,
        operation: (updateStage) => _syncConnectController.connect(
          credentials: selectedCredentials,
          reconnectActive: reconnectBinding != null,
          confirmExistingReplacement: _confirmExistingReplacement,
          onProgress: updateStage,
        ),
      );
      if (!mounted) return;
      final binding = switch (outcome) {
        WebDavSyncConnectCancelled() => null,
        WebDavSyncConnectActive active => active.binding,
        WebDavSyncConnectAdoptedFinishing finishing => finishing.binding,
        WebDavSyncConnectPreHandoffFailure failure => throw failure.error,
        WebDavSyncConnectPostHandoffFailure failure => throw failure.error,
      };
      if (binding == null) return;
      if (!mounted) return;
      setState(() => _syncBinding = binding);
      try {
        await _rememberSync(selectedCredentials);
        await _loadSavedSyncs();
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Sync connected, but the login could not be added to saved syncs.',
              ),
            ),
          );
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_completionMessage(binding.lifecycle))),
      );
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      try {
        if (didPause) await reconfiguration!.resumeAfterReconfiguration();
        if (mounted) await _loadActiveSyncState();
        if (mounted) await _loadSavedSyncs();
      } catch (error) {
        if (mounted) _showError(error);
      } finally {
        if (mounted) setState(() => _syncBusy = false);
      }
    }
  }

  Future<void> _rememberSync(WebDavSyncLoginCredentials credentials) async {
    final entry = WebDavSavedSync(
      name: credentials.serverName,
      credentials: credentials,
    );
    final rows = await _savedSyncStore.load();
    final existing = rows.where((row) => row.id == entry.id).firstOrNull;
    await _savedSyncStore.save(
      WebDavSavedSync(
        name: existing?.name ?? entry.name,
        credentials: credentials,
      ),
    );
  }

  Future<void> _loadSavedSyncs() async {
    try {
      String? activeId;
      final binding = (await _syncService.store.load()).activeBinding;
      if (binding != null) {
        final secrets = await _syncService.store.readSecrets(binding);
        final current = WebDavSavedSync(
          name: binding.location.serverName,
          credentials: WebDavSyncLoginCredentials(
            endpoint: binding.location.endpoint,
            username: secrets.username,
            password: secrets.password,
            serverName: binding.location.serverName,
          ),
        );
        await _savedSyncStore.importCurrentIfNeeded(current);
        if (binding.lifecycle == WebDavSyncLifecycle.active) {
          activeId = current.id;
        }
      }
      final saved = await _savedSyncStore.load();
      if (mounted) {
        setState(() {
          _savedSyncs = saved;
          _activeSavedSyncId = activeId;
        });
      }
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _addSync() async {
    if (!mounted || _syncBusy) return;
    setState(() => _syncBusy = true);
    WebDavSavedSync? added;
    try {
      await _syncAuthorization.requireAdmin();
      if (!mounted) return;
      final credentials = widget.launchSyncLogin != null
          ? await widget.launchSyncLogin!(context, _syncConnectController)
          : await Navigator.of(context).push<WebDavSyncLoginCredentials>(
              MaterialPageRoute(
                builder: (_) => WebDavSyncLoginScreen(
                  connectController: _syncConnectController,
                ),
              ),
            );
      if (credentials == null || !mounted) return;
      await _rememberSync(credentials);
      await _loadSavedSyncs();
      added = WebDavSavedSync(
        name: credentials.serverName,
        credentials: credentials,
      );
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _syncBusy = false);
    }
    if (mounted && added != null) await _openSyncVersions(added);
  }

  Future<void> _openSyncVersions(WebDavSavedSync sync) async {
    if (!mounted || _syncBusy) return;
    setState(() => _syncBusy = true);
    Object? action;
    WebDavSyncFolderExisting? existing;
    try {
      final result = await runWebDavForegroundSync(
        context,
        title: 'Loading sync',
        stage: 'Checking saved versions…',
        operation: (_) async {
          final inspection = await _syncConnectController.inspect(
            sync.credentials,
          );
          if (inspection is! WebDavSyncFolderExisting) {
            return <WebDavSyncVersion>[];
          }
          existing = inspection;
          if (widget.loadSyncVersions != null) {
            return widget.loadSyncVersions!(inspection);
          }
          return _syncAuthorization.runForAdminSession((beforeSend) async {
            final client = WebDavProtocolClient(
              endpoint: sync.credentials.endpoint,
              credentials: WebDavCredentials(
                username: sync.credentials.username,
                password: sync.credentials.password,
              ),
            );
            try {
              return await WebDavSyncVersions(
                client,
                folderPath: inspection.location.folderPath,
                beforeSend: beforeSend,
              ).list();
            } finally {
              client.close();
            }
          });
        },
      );
      if (!mounted) return;
      final active = sync.id == _activeSavedSyncId;
      action = await showSettingsDialog<Object>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(sync.name),
          scrollable: true,
          content: SizedBox(
            width: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '${sync.credentials.username} • ${sync.credentials.endpoint.host}',
                ),
                const SizedBox(height: 16),
                if (!active)
                  FilledButton.icon(
                    onPressed: () => Navigator.pop(dialogContext, 'latest'),
                    icon: const Icon(Icons.sync),
                    label: Text(
                      existing == null
                          ? 'Start syncing this device'
                          : 'Use current sync data',
                    ),
                  ),
                const SizedBox(height: 20),
                const Text(
                  'Saved versions',
                  style: TextStyle(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Load a dated snapshot, then continue syncing. Restored data will be shared with your other devices through normal sync.',
                ),
                if (result.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'No snapshots yet. A snapshot is saved after each successful manual sync.',
                    ),
                  ),
                for (final version in result)
                  ListTile(
                    leading: const Icon(Icons.history),
                    title: Text(
                      _formatSyncTime(version.createdAt.millisecondsSinceEpoch),
                    ),
                    subtitle: Text(
                      version.sizeBytes == null
                          ? 'Encrypted snapshot'
                          : '${(version.sizeBytes! / 1048576).toStringAsFixed(1)} MB • encrypted',
                    ),
                    trailing: const Icon(Icons.restore),
                    onTap: () => Navigator.pop(dialogContext, version),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (action is WebDavSyncVersion && existing != null) {
        await ProfileBackupFlows(context).restoreSyncVersion(existing!, action);
        if (mounted) await _loadSyncState();
      }
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _syncBusy = false);
    }
    if (mounted && action == 'latest') await _configureSync(saved: sync);
  }

  Future<void> _editSavedSync(WebDavSavedSync sync) async {
    try {
      await _syncAuthorization.requireAdmin();
      if (!mounted) return;
      final controller = TextEditingController(text: sync.name);
      final name = await showSettingsDialog<String>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Name this sync'),
          content: TvTextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Sync name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                if (controller.text.trim().isNotEmpty) {
                  Navigator.pop(context, controller.text.trim());
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      );
      // Dispose after the dialog's reverse transition releases its text field.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      controller.dispose();
      if (name == null || !mounted) return;
      await _savedSyncStore.save(
        WebDavSavedSync(name: name, credentials: sync.credentials),
      );
      await _loadSavedSyncs();
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Future<void> _removeSavedSync(WebDavSavedSync sync) async {
    try {
      await _syncAuthorization.requireAdmin();
      await _savedSyncStore.remove(sync.id);
      await _loadSavedSyncs();
    } catch (error) {
      if (mounted) _showError(error);
    }
  }

  Widget _buildSavedSyncs() => SettingsSection(
    title: 'Your syncs',
    blurb:
        'Add a connection, then choose current data or a dated snapshot. One sync is active on this device at a time.',
    children: [
      SettingsTile(
        icon: Icons.add,
        title: 'Add sync',
        subtitle: 'Save a WebDAV connection',
        enabled: !_syncBusy,
        onTap: _addSync,
      ),
      for (final sync in _savedSyncs)
        SettingsTile(
          icon: sync.id == _activeSavedSyncId
              ? Icons.check_circle_outline
              : Icons.cloud_outlined,
          title: sync.name,
          subtitle:
              '${sync.id == _activeSavedSyncId ? 'Active • ' : ''}${sync.credentials.username} • Versions and restore',
          enabled: !_syncBusy,
          onTap: () => _openSyncVersions(sync),
          trailing: PopupMenuButton<String>(
            enabled: !_syncBusy,
            tooltip: 'Manage saved sync',
            onSelected: (action) => action == 'rename'
                ? _editSavedSync(sync)
                : _removeSavedSync(sync),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'rename', child: Text('Rename')),
              PopupMenuItem(value: 'remove', child: Text('Remove saved login')),
            ],
          ),
        ),
    ],
  );

  Future<bool> _confirmExistingReplacement() async {
    return await showSettingsDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AlertDialog(
            title: const Text('Use sync data from this account?'),
            content: const Text(
              'Existing profiles and connections on this device will be '
              'replaced. Create a manual backup first if you want to keep '
              'a copy of your current data. IPTV channel and '
              'guide caches rebuild; Debrify TV channels are not included.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Use sync data'),
              ),
            ],
          ),
        ) ??
        false;
  }

  WebDavSyncLogoutController? get _logoutController =>
      _syncActivation is WebDavSyncLogoutController
      ? _syncActivation as WebDavSyncLogoutController
      : null;

  Future<bool> _forgetConnection() async {
    final controller = _logoutController;
    if (_syncBusy || controller == null) return false;
    final confirmed = await showSettingsDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Forget WebDAV connection?'),
        content: const Text(
          'Remove the saved connection from this device without contacting WebDAV. '
          'Your profiles and data stay here. You can then connect again.\n\n'
          'The old account may still list this device as connected. '
          'Data on WebDAV and your other devices will not be changed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Forget connection'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return false;
    setState(() => _syncBusy = true);
    try {
      await controller.logout(localOnly: true);
      if (!mounted) return false;
      await _loadSyncState();
      if (!mounted) return false;
      setState(() {
        _runtimeStatus = null;
        _syncStateMessage = null;
      });
      return true;
    } catch (error) {
      if (mounted) _showError(error);
      return false;
    } finally {
      if (mounted) setState(() => _syncBusy = false);
    }
  }

  Future<void> _logout() async {
    final controller = _logoutController;
    if (!mounted || _syncBusy || controller == null) return;
    final confirmed = await showSettingsDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('Log out of WebDAV sync?'),
        content: const Text(
          'This device will stop syncing and leave the connected devices list. '
          'Saved syncs remain available in the list below.\n\n'
          'Your profiles and data stay on this device. Already synced data stays '
          'on WebDAV so you and your other devices can use it later. Changes '
          'that have not synced stay only on this device.\n\n'
          'If WebDAV is unavailable, you can forget the connection on this device after trying logout.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Log out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _syncBusy = true);
    try {
      await runWebDavForegroundSync(
        context,
        title: 'Logging out of WebDAV',
        stage: 'Unregistering this device and removing its saved login…',
        operation: (_) => controller.logout(),
      );
      if (!mounted) return;
      await _loadSyncState();
      if (!mounted) return;
      setState(() {
        _runtimeStatus = null;
        _syncStateMessage = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Logged out. Your data is still on this device.'),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      await _loadSyncState();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _logoutPending
                ? 'Logout could not be confirmed. Retry or choose Forget connection to disconnect on this device.'
                : _userFacingSyncError(error),
          ),
          action: SnackBarAction(label: 'Retry', onPressed: _logout),
        ),
      );
    } finally {
      if (mounted) setState(() => _syncBusy = false);
    }
  }

  Future<void> _syncNow() async {
    final activation = _syncActivation;
    if (!mounted || _syncBusy || activation == null) return;
    setState(() => _syncBusy = true);
    try {
      final report = await runWebDavForegroundSync(
        context,
        stage: 'Checking and exchanging sync data…',
        operation: (_) => activation.syncNow(),
      );
      if (!mounted) return;
      var snapshotSaved = false;
      if (report.disposition == WebDavSyncCycleDisposition.completed &&
          report.localPublicationConfirmed &&
          !report.localChangeFollowUp &&
          !report.localProfilesSuppressed) {
        try {
          snapshotSaved = await _saveSnapshotAfterManualSync();
        } catch (error) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Sync finished, but its snapshot could not be saved: ${_userFacingSyncError(error)}',
                ),
              ),
            );
          }
        }
      }
      if (!mounted) return;
      final message = switch (report.disposition) {
        WebDavSyncCycleDisposition.completed =>
          report.localChangeFollowUp ||
                  !report.localPublicationConfirmed ||
                  report.localProfilesSuppressed
              ? 'Sync still has pending changes. Keep Debrify open and retry.'
              : snapshotSaved
              ? 'WebDAV Sync is up to date. Snapshot saved.'
              : report.statusHint ?? 'WebDAV Sync is up to date.',
        WebDavSyncCycleDisposition.clockPaused =>
          'Sync is paused because the device or server clock needs attention.',
        WebDavSyncCycleDisposition.adoptionBlocked =>
          'Sync is waiting for profile replacement to finish.',
        WebDavSyncCycleDisposition.capacityBlocked =>
          'Sync is over its saved-activity limit. Clear older history or '
              'lists, then try again.',
        WebDavSyncCycleDisposition.seedRepairRequired =>
          'Sync data for this device is being rebuilt.',
        WebDavSyncCycleDisposition.inactive => 'Sync is currently paused.',
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          action:
              report.disposition != WebDavSyncCycleDisposition.completed ||
                  !report.localPublicationConfirmed ||
                  report.localChangeFollowUp ||
                  report.localProfilesSuppressed
              ? SnackBarAction(label: 'Retry', onPressed: _syncNow)
              : null,
        ),
      );
      await _loadSyncState();
    } catch (error) {
      if (mounted) _showError(error, onRetry: _syncNow);
    } finally {
      if (mounted) setState(() => _syncBusy = false);
    }
  }

  Future<bool> _saveSnapshotAfterManualSync() async {
    final binding = (await _syncService.store.load()).activeBinding;
    if (binding == null || binding.lifecycle != WebDavSyncLifecycle.active) {
      return false;
    }
    final secrets = await _syncService.store.readSecrets(binding);
    final credentials = WebDavSyncLoginCredentials(
      endpoint: binding.location.endpoint,
      username: secrets.username,
      password: secrets.password,
      serverName: binding.location.serverName,
    );
    final inspection = await _syncConnectController.inspect(credentials);
    if (inspection is! WebDavSyncFolderExisting) {
      throw StateError('The connected sync is no longer available.');
    }
    await ProfileBackupFlows(
      context,
    ).createSyncVersion(inspection, announce: false);
    return true;
  }

  Future<void> _syncDebrifyTv() async {
    final controller = _tvManualController;
    if (_syncBusy || _tvSyncLaunching || controller == null) return;
    _tvSyncLaunching = true;
    _DebrifyTvSyncOperation? operation;
    try {
      final availability = await controller.tvManualAvailability();
      if (!mounted) return;
      setState(() => _tvManualAvailability = availability);
      if (availability != WebDavSyncTvManualAvailability.available) return;
      setState(() => _syncBusy = true);
      operation = _DebrifyTvSyncOperation(controller);
      _tvSyncOperation = operation;
      var report = await showSettingsDialog<WebDavSyncTvManualReport>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _DebrifyTvSyncProgressDialog(operation: operation!),
      );
      report ??= await operation.terminal;
      if (!mounted) return;
      final message = switch (report.disposition) {
        WebDavSyncTvManualDisposition.completed =>
          'Debrify TV sync is up to date.',
        WebDavSyncTvManualDisposition.cancelled =>
          'Debrify TV sync stopped safely.',
        WebDavSyncTvManualDisposition.inactive =>
          'Enable WebDAV Sync before syncing Debrify TV.',
        WebDavSyncTvManualDisposition.firstJoinPending =>
          'Finish the first sync before syncing Debrify TV.',
        WebDavSyncTvManualDisposition.cycleRunning =>
          'Another sync is running. Try Debrify TV again when it finishes.',
        WebDavSyncTvManualDisposition.televisionPlayback =>
          'Stop TV playback, then run Debrify TV sync again.',
        WebDavSyncTvManualDisposition.tvOsLowMemory =>
          'Apple TV is low on memory. Wait a few minutes, then try again.',
        WebDavSyncTvManualDisposition.clockPaused =>
          'Debrify TV sync is paused because the device or server clock needs attention.',
        WebDavSyncTvManualDisposition.conflict =>
          'Debrify TV changed during sync. Run it again to finish.',
      };
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (operation != null) {
        try {
          await operation.cancelAndWait();
        } catch (_) {
          // The operation error was already surfaced by the owning handler.
        }
      }
      if (identical(_tvSyncOperation, operation)) _tvSyncOperation = null;
      _tvSyncLaunching = false;
      if (mounted && _syncBusy) setState(() => _syncBusy = false);
    }
    if (mounted) await _loadActiveSyncState();
  }

  Future<void> _repairCredentials() async {
    if (_syncBusy) return;
    setState(() => _syncBusy = true);
    final reconfiguration =
        _syncActivation is WebDavSyncReconfigurationController
        ? _syncActivation as WebDavSyncReconfigurationController
        : null;
    var reloadAfterResume = false;
    var didPause = false;
    try {
      await _syncAuthorization.requireAdmin();
      var binding = _syncBinding;
      if (_logoutPending) {
        final snapshot = await _syncService.store.load();
        if (!mounted) return;
        final bindings = snapshot.bindings.values
            .where(
              (item) =>
                  item.circleId != null &&
                  snapshot.namespaceFor(item)?.markerBytes != null,
            )
            .toList();
        binding = await showSettingsDialog<WebDavSyncBinding>(
          context: context,
          builder: (dialogContext) => SimpleDialog(
            title: const Text('Choose account to repair'),
            children: [
              for (final item in bindings)
                SimpleDialogOption(
                  onPressed: () => Navigator.of(dialogContext).pop(item),
                  child: Text(
                    '${item.location.serverName}\n${item.location.endpoint.host} · ${item.location.folderPath}'
                    '${snapshot.namespaceFor(item)?.values['logoutNeedsAttentionBindingId'] == item.id ? '\nLogout stopped at this account' : ''}',
                  ),
                ),
            ],
          ),
        );
      }
      final repairBinding = binding;
      if (repairBinding == null || repairBinding.circleId == null) return;

      final currentSecrets = await _syncService.store.readSecrets(
        repairBinding,
      );
      if (!mounted) return;
      final input = await showSettingsDialog<_SyncCredentialInput>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            _SyncCredentialDialog(initialUsername: currentSecrets.username),
      );
      if (input == null || !mounted) return;
      if (reconfiguration != null) {
        reconfiguration.pauseForReconfiguration();
        didPause = true;
      }
      final config = WebDavConfig(
        id: 'webdav-sync-credentials',
        name: repairBinding.location.serverName,
        baseUrl: repairBinding.location.endpoint.toString(),
        username: input.username,
        password: input.password,
      );
      final repaired = await _syncAuthorization.runForActiveBinding((
        beforeSend,
      ) async {
        final inspection = await _syncService.inspectFolder(
          config: config,
          folderPath: repairBinding.location.folderPath,
          context: WebDavSyncFolderInspectionContext.repair,
          repairBindingId: repairBinding.id,
          beforeSend: beforeSend,
        );
        if (inspection is! WebDavSyncFolderExisting) {
          throw const WebDavSyncRootMissingException();
        }
        return _syncService.configureExistingRoot(
          inspection: inspection,
          beforeCommit: beforeSend,
        );
      });
      if (!mounted) return;
      setState(() => _syncBinding = repaired);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('WebDAV Sync credentials verified.')),
      );
      reloadAfterResume = true;
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      try {
        if (didPause) await reconfiguration!.resumeAfterReconfiguration();
      } catch (error) {
        if (mounted) _showError(error);
      } finally {
        if (mounted) setState(() => _syncBusy = false);
      }
    }
    if (reloadAfterResume && mounted) await _loadActiveSyncState();
  }

  Future<String?> _askDeviceName(String name) => showSettingsDialog<String>(
    context: context,
    builder: (_) => SyncDeviceNameDialog(initialName: name),
  );

  Future<void> _manageDevices() async {
    final management = _management;
    if (management == null || _syncBusy) return;
    setState(() => _syncBusy = true);
    try {
      final devices = await runWebDavForegroundSync(
        context,
        title: 'Loading devices',
        stage: 'Checking the devices connected to this account…',
        operation: (_) => management.listDevices(),
      );
      if (!mounted) return;
      final target = await showSettingsDialog<String>(
        context: context,
        builder: (_) => SyncDevicesDialog(
          devices: devices,
          canRename: management is WebDavSyncDeviceNamingController,
        ),
      );
      if (!mounted || target == null) return;
      if (target == '@rename' &&
          management is WebDavSyncDeviceNamingController) {
        final current = devices.where((device) => device.isThisDevice).first;
        final name = await _askDeviceName(current.displayName ?? 'This device');
        if (!mounted || name == null) return;
        await runWebDavForegroundSync(
          context,
          title: 'Renaming device',
          stage: 'Saving the name for your connected devices…',
          operation: (_) => (management as WebDavSyncDeviceNamingController)
              .renameThisDevice(name),
        );
        if (mounted) {
          setState(() => _syncBusy = false);
          await _manageDevices();
        }
        return;
      }
      final confirmed = await showSettingsDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => AlertDialog(
          scrollable: true,
          title: const Text('Remove this device?'),
          content: const Text(
            'Delete this device’s sync files and remove its registration. '
            'Its local data stays intact. When the device next connects, it '
            'will be signed out and must sign in again to rejoin. '
            'Update all devices first: older app versions cannot enforce remote removal.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Remove device'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      await runWebDavForegroundSync(
        context,
        title: 'Removing device',
        stage: 'Removing this device from the list…',
        operation: (_) => management.forgetDevice(target),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Device removed. It must sign in again to rejoin.'),
        ),
      );
      await _loadActiveSyncState();
    } catch (error) {
      if (mounted) _showError(error);
    } finally {
      if (mounted) setState(() => _syncBusy = false);
    }
  }

  void _showError(Object error, {VoidCallback? onRetry}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_userFacingSyncError(error)),
        action: onRetry == null
            ? null
            : SnackBarAction(label: 'Retry', onPressed: onRetry),
        backgroundColor: Colors.red,
      ),
    );
  }

  static String _userFacingSyncError(Object error) {
    final message = error
        .toString()
        .replaceFirst(
          RegExp(r'^(?:Exception|FormatException|Bad state):\s*'),
          '',
        )
        .replaceAll('\n', ' ')
        .trim();
    // Runtime and parser failures are useful in diagnostics, but protocol
    // implementation vocabulary must never become product copy through the
    // generic snackbar or a persisted binding error.
    if (message.isEmpty || _internalSyncVocabulary.hasMatch(message)) {
      return 'WebDAV Sync could not complete this operation. '
          'Try again or verify the WebDAV account.';
    }
    return message;
  }

  String _syncStatus() {
    final binding = _syncBinding;
    if (binding == null) return SettingsRows.enableWebDavSync.subtitle;
    return switch (binding.lifecycle) {
      WebDavSyncLifecycle.unconfigured => 'Sign in to a WebDAV account',
      WebDavSyncLifecycle.configured =>
        'Account selected; verification pending',
      WebDavSyncLifecycle.awaitingSeedCommit =>
        'Ready to initialize WebDAV Sync',
      WebDavSyncLifecycle.rootVerified => 'WebDAV account verified',
      WebDavSyncLifecycle.awaitingAdoption =>
        binding.errorMessage == null
            ? 'Finishing first sync…'
            : _userFacingSyncError(binding.errorMessage!),
      WebDavSyncLifecycle.active => 'Sync is active',
      WebDavSyncLifecycle.error =>
        binding.errorMessage == null
            ? 'Sync needs attention'
            : _userFacingSyncError(binding.errorMessage!),
    };
  }

  static String _completionMessage(WebDavSyncLifecycle lifecycle) =>
      switch (lifecycle) {
        WebDavSyncLifecycle.awaitingSeedCommit =>
          'WebDAV Sync is ready to initialize.',
        WebDavSyncLifecycle.rootVerified => 'WebDAV account verified.',
        WebDavSyncLifecycle.awaitingAdoption => 'Finishing first sync…',
        _ => 'WebDAV Sync configuration updated.',
      };

  Widget _buildSyncSection() {
    final active = _syncBinding?.lifecycle == WebDavSyncLifecycle.active;
    final live =
        active &&
        !_logoutPending &&
        _runtimeStatus?.automaticSyncActive == true &&
        _runtimeStatus?.clockPauseReason == null &&
        _runtimeStatus?.localStateMissing == false;
    final statusLabel = live
        ? 'Automatic sync is active'
        : active
        ? 'Automatic sync is paused or limited'
        : 'Sync is not active';
    final finishingFirstSync =
        _syncBinding?.lifecycle == WebDavSyncLifecycle.awaitingAdoption &&
        _syncBinding?.errorMessage == null;
    final credentialRepairAvailable =
        _logoutPending ||
        (_syncBinding?.lifecycle == WebDavSyncLifecycle.error &&
            _syncBinding?.circleId != null &&
            _syncBinding?.requiresStateReconnect != true);
    final tvControllerAvailable = _tvManualController != null;
    final tvButtonEnabled =
        active &&
        !_logoutPending &&
        tvControllerAvailable &&
        !_syncBusy &&
        _tvManualAvailability == WebDavSyncTvManualAvailability.available;
    final tvSubtitle = switch (_tvManualAvailability) {
      WebDavSyncTvManualAvailability.available
          when _runtimeStatus?.tvChangesPending == true =>
        'Changes are waiting for a manual sync',
      WebDavSyncTvManualAvailability.available => 'Ready to sync',
      WebDavSyncTvManualAvailability.inactive =>
        'Enable WebDAV Sync to use manual TV sync',
      WebDavSyncTvManualAvailability.firstJoinPending =>
        'Finish the first sync before syncing Debrify TV',
      WebDavSyncTvManualAvailability.cycleRunning =>
        'Wait for the current sync to finish',
      WebDavSyncTvManualAvailability.televisionPlayback =>
        'Stop TV playback, then try again',
      WebDavSyncTvManualAvailability.tvOsLowMemory =>
        'Apple TV is low on memory; wait a few minutes, then try again',
    };
    final connectedName = _syncBinding?.location.serverName;
    final lastSync = _runtimeStatus?.lastSuccessfulSyncMs;
    final clockMessage = _runtimeStatus == null
        ? null
        : _clockStatusMessage(_runtimeStatus!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsSection(
          title: 'Sync status',
          blurb: active
              ? 'Your profiles, app settings and watch progress sync automatically while the app is open. Device-specific performance settings stay local.'
              : 'Keep your profiles, app settings and watch progress together across your devices. Device-specific performance settings stay local.',
          children: [
            ListTile(
              leading: Icon(
                _logoutPending
                    ? Icons.cloud_off_outlined
                    : active
                    ? Icons.cloud_done_outlined
                    : Icons.cloud_outlined,
                color: active ? Theme.of(context).colorScheme.primary : null,
              ),
              title: Row(
                children: [
                  Tooltip(
                    message: statusLabel,
                    child: Semantics(
                      label: statusLabel,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: live
                              ? Colors.green
                              : active || finishingFirstSync || _logoutPending
                              ? Colors.amber
                              : Theme.of(context).colorScheme.outline,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _logoutPending
                          ? 'Logout needs attention'
                          : active
                          ? 'Connected to $connectedName'
                          : finishingFirstSync
                          ? 'Connecting to $connectedName'
                          : 'Not connected',
                    ),
                  ),
                ],
              ),
              subtitle: Text(
                _logoutPending
                    ? 'Sync is paused. Retry logout to finish removing this connection.'
                    : finishingFirstSync
                    ? 'Setting up sync. Keep the app open while this finishes.'
                    : active
                    ? _runtimeStatus == null
                          ? _statusReadFailed || _management == null
                                ? 'Sync status unavailable'
                                : 'Loading sync status…'
                          : _runtimeStatus!.localStateMissing
                          ? 'Sync status unavailable'
                          : lastSync == null
                          ? 'Waiting for the first completed sync'
                          : 'Last synced ${_formatSyncTime(lastSync)}'
                    : _syncBinding == null
                    ? _deviceRemoved
                          ? WebDavSyncDeviceRemovedException.message
                          : 'Connect the same WebDAV account on each device.'
                    : _syncStatus(),
              ),
            ),
            if (!active && _syncBinding != null)
              SettingsTile(
                icon: Icons.login_rounded,
                title: 'Continue setup',
                subtitle: 'Finish connecting this device',
                enabled: !_syncBusy,
                onTap: _configureSync,
              ),
            if (credentialRepairAvailable)
              SettingsTile(
                icon: Icons.key_rounded,
                title: 'Update password',
                subtitle: 'Restore access to your WebDAV account',
                enabled: !_syncBusy,
                onTap: _repairCredentials,
              ),
            if (active)
              SettingsTile(
                icon: Icons.sync,
                title: 'Sync now',
                subtitle: 'Send your changes and check for updates',
                enabled:
                    !_syncBusy && !_logoutPending && _syncActivation != null,
                onTap: _syncNow,
              ),
            SettingsTile(
              icon: Icons.menu_book_rounded,
              title: 'Setup guide',
              subtitle: 'Koofr setup, app passwords and connecting devices',
              trailing: Icon(
                PlatformUtil.isTelevision
                    ? Icons.qr_code_rounded
                    : Icons.open_in_new_rounded,
                size: 20,
              ),
              onTap: _openSetupGuide,
            ),
          ],
        ),
        if (clockMessage != null || _syncStateMessage != null) ...[
          const SizedBox(height: 12),
          Text(
            clockMessage ?? _syncStateMessage!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (_syncBinding != null) ...[
          const SizedBox(height: 16),
          SettingsSection(
            title: 'Account and devices',
            children: [
              if (active && _management != null)
                SettingsTile(
                  icon: Icons.devices_other,
                  title: 'Connected devices',
                  subtitle: 'Manage devices using this sync account',
                  enabled: !_syncBusy && !_logoutPending,
                  onTap: _manageDevices,
                ),
              if (_logoutController != null)
                SettingsTile(
                  icon: Icons.logout_rounded,
                  title: _logoutPending ? 'Retry logout' : 'Log out',
                  subtitle: 'Stop syncing with this account',
                  enabled: !_syncBusy,
                  onTap: _logout,
                ),
              if (_logoutPending && _logoutController != null)
                SettingsTile(
                  icon: Icons.link_off_rounded,
                  title: 'Forget connection',
                  subtitle:
                      'Disconnect on this device if WebDAV is unavailable',
                  enabled: !_syncBusy,
                  onTap: () async {
                    await _forgetConnection();
                  },
                ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        SettingsSection(
          title: 'Debrify TV channels',
          blurb:
              'Channels and saved torrent pools transfer only when you sync them here. Run this on both devices after changing channels.',
          children: [
            SettingsTile(
              icon: Icons.live_tv_rounded,
              title: 'Sync channels now',
              subtitle: tvControllerAvailable
                  ? tvSubtitle
                  : 'Connect WebDAV to sync your channels',
              enabled: tvButtonEnabled,
              onTap: _syncDebrifyTv,
            ),
          ],
        ),
        if (active && _runtimeStatus?.lastTvSyncMs != null) ...[
          const SizedBox(height: 8),
          Text(
            'Channels last synced ${_formatSyncTime(_runtimeStatus!.lastTvSyncMs!)}',
            style: const TextStyle(fontSize: 12.5),
          ),
        ],
        if (active && _runtimeStatus != null) ...[
          const SizedBox(height: 12),
          ExpansionTile(
            title: const Text('Sync details'),
            childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            expandedCrossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_pollStatusMessage(_runtimeStatus!)),
              const SizedBox(height: 8),
              const Text(
                'IPTV playlists, favorites and watch history sync automatically. Channel listings and TV guides are downloaded separately on each device.',
              ),
            ],
          ),
        ],
        if (active && !_logoutPending) ...[
          const SizedBox(height: 16),
          SettingsSection(
            title: 'Diagnostics',
            children: [
              SettingsToggleTile(
                icon: Icons.upload_file_outlined,
                title: 'Upload diagnostic logs to WebDAV',
                subtitle:
                    'This device only. Saves one rolling file in logs/ every 5 minutes while the app is open. Anyone with folder access can read it.',
                subtitleMaxLines: 4,
                value: _logUploadEnabled,
                onChanged: _setLogUpload,
              ),
              if (_logUploadEnabled)
                SettingsTile(
                  icon: Icons.cloud_upload_outlined,
                  title: _logUploading ? 'Uploading logs…' : 'Upload logs now',
                  subtitle:
                      'Replace this device’s file with its latest diagnostic history',
                  enabled: !_logUploading && !_logSettingsBusy && !_syncBusy,
                  onTap: _uploadLogsNow,
                ),
            ],
          ),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  static String _formatSyncTime(int milliseconds) => DateFormat.yMd()
      .add_jm()
      .format(DateTime.fromMillisecondsSinceEpoch(milliseconds).toLocal());

  static String _pollStatusMessage(WebDavSyncRuntimeStatus status) =>
      switch (status.pollState) {
        WebDavSyncPollState.active when status.lastRemoteChangeMs != null =>
          'Checking for changes every minute • Last remote change '
              '${_formatSyncTime(status.lastRemoteChangeMs!)}',
        WebDavSyncPollState.active => 'Checking for changes every minute',
        WebDavSyncPollState.pausedBackoff =>
          'Checking for changes paused; syncing continues every 15 min',
        WebDavSyncPollState.disabledNoValidators =>
          'Server does not report changes; syncing every 15 min',
        WebDavSyncPollState.gated => 'Checking for changes is currently paused',
      };

  static String? _clockStatusMessage(WebDavSyncRuntimeStatus status) {
    final paused = switch (status.clockPauseReason) {
      WebDavSyncClockPauseReason.missingServerDate =>
        'Sync is paused because the WebDAV server did not provide a reliable clock.',
      WebDavSyncClockPauseReason.offsetOutlier =>
        'Sync is paused while a large device or server clock change is confirmed.',
      WebDavSyncClockPauseReason.serverMovedBackwards =>
        'Sync is paused because the WebDAV server clock moved backwards.',
      null => null,
    };
    if (paused != null) return paused;
    return status.deviceClockWarning
        ? 'This device clock differs substantially from the WebDAV server; sync timestamps use server time.'
        : null;
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Sync & versions',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kSettingsMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_syncFeatureEnabled) ...[
                  _buildSavedSyncs(),
                  const SizedBox(height: 16),
                  _buildSyncSection(),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

final class _DebrifyTvSyncProgressDialog extends StatefulWidget {
  const _DebrifyTvSyncProgressDialog({required this.operation});

  final _DebrifyTvSyncOperation operation;

  @override
  State<_DebrifyTvSyncProgressDialog> createState() =>
      _DebrifyTvSyncProgressDialogState();
}

final class _DebrifyTvSyncProgressDialogState
    extends State<_DebrifyTvSyncProgressDialog> {
  WebDavSyncTvManualStage _stage = WebDavSyncTvManualStage.reading;
  bool _stopping = false;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      final report = await widget.operation.start(
        onStage: (stage) {
          if (mounted) setState(() => _stage = stage);
        },
      );
      if (mounted) Navigator.of(context).pop(report);
    } catch (_) {
      if (mounted) Navigator.of(context).pop();
    }
  }

  void _stop() {
    if (_stopping) return;
    widget.operation.cancel();
    setState(() => _stopping = true);
  }

  @override
  void dispose() {
    widget.operation.cancel();
    super.dispose();
  }

  String get _stageLabel => switch (_stage) {
    WebDavSyncTvManualStage.reading => 'Reading',
    WebDavSyncTvManualStage.merging => 'Merging',
    WebDavSyncTvManualStage.applying => 'Applying',
    WebDavSyncTvManualStage.publishing => 'Publishing',
  };

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        title: const Text('Syncing Debrify TV'),
        content: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox.square(
              dimension: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
            const SizedBox(width: 16),
            Text(_stopping ? 'Stopping after this stage…' : _stageLabel),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _stopping ? null : _stop,
            child: const Text('Stop'),
          ),
        ],
      ),
    );
  }
}

final class _DebrifyTvSyncOperation {
  _DebrifyTvSyncOperation(this._controller);

  final WebDavSyncTvManualController _controller;
  final WebDavSyncTvCancellationToken _token = WebDavSyncTvCancellationToken();
  Future<WebDavSyncTvManualReport>? _terminal;

  Future<WebDavSyncTvManualReport> start({
    WebDavSyncTvStageCallback? onStage,
  }) => _terminal ??= _controller.syncDebrifyTv(
    cancellationToken: _token,
    onStage: onStage,
  );

  Future<WebDavSyncTvManualReport> get terminal => _terminal!;

  void cancel() => _token.cancel();

  Future<void> cancelAndWait() async {
    cancel();
    final terminal = _terminal;
    if (terminal != null) await terminal;
  }
}

final RegExp _internalSyncVocabulary = RegExp(
  r'circle|seed|join|enroll|passphrase',
  caseSensitive: false,
);

final class _SyncCredentialInput {
  const _SyncCredentialInput({required this.username, required this.password});

  final String username;
  final String password;
}

final class _SyncCredentialDialog extends StatefulWidget {
  const _SyncCredentialDialog({required this.initialUsername});

  final String initialUsername;

  @override
  State<_SyncCredentialDialog> createState() => _SyncCredentialDialogState();
}

final class _SyncCredentialDialogState extends State<_SyncCredentialDialog> {
  late final TextEditingController _username = TextEditingController(
    text: widget.initialUsername,
  );
  final TextEditingController _password = TextEditingController();

  bool get _valid =>
      _username.text.trim().isNotEmpty && _password.text.isNotEmpty;

  @override
  void dispose() {
    _username.dispose();
    _password
      ..clear()
      ..dispose();
    super.dispose();
  }

  void _submit() {
    if (!_valid) return;
    Navigator.of(context).pop(
      _SyncCredentialInput(
        username: _username.text.trim(),
        password: _password.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Verify sync credentials'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TvTextField(
              controller: _username,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'WebDAV username'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TvTextField(
              controller: _password,
              obscureText: true,
              textInputAction: TextInputAction.done,
              keyboardSubmitLabel: 'Verify',
              decoration: const InputDecoration(labelText: 'WebDAV password'),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _valid ? _submit : null,
          child: const Text('Verify'),
        ),
      ],
    );
  }
}
