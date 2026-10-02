import '../../widgets/webdav_sync/webdav_foreground_sync.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../services/webdav_protocol_client.dart';
import '../../services/webdav_sync/webdav_sync_connect_controller.dart';
import '../../services/webdav_sync/webdav_sync_models.dart';
import '../../services/webdav_sync/webdav_sync_setup_service.dart';
import '../../widgets/tv_text_field.dart';
import '../settings/widgets/settings_widgets.dart';

enum WebDavSyncProviderPreset { koofr, pCloud, custom }

enum PCloudServerSite { europe, unitedStates }

typedef WebDavSyncLoginInspector =
    Future<Object?> Function(WebDavSyncLoginCredentials credentials);

/// Login dedicated to continuous WebDAV Sync.
///
/// Credentials stay in memory and are returned to the owning setup flow. This
/// screen deliberately has no dependency on the normal cloud-account registry.
final class WebDavSyncLoginScreen extends StatefulWidget {
  const WebDavSyncLoginScreen({
    super.key,
    this.connectController,
    this.inspect,
    this.repairBinding,
    this.initialUsername,
  }) : assert(
         connectController != null || inspect != null,
         'A WebDAV Sync inspector is required',
       ),
       assert(
         repairBinding == null || connectController != null,
         'A repair login requires the sync controller',
       );

  static final Uri koofrEndpoint = Uri.parse(
    'https://app.koofr.net/dav/Koofr/',
  );
  static final Uri pCloudEuEndpoint = Uri.parse('https://ewebdav.pcloud.com/');
  static final Uri pCloudUsEndpoint = Uri.parse('https://webdav.pcloud.com/');
  static final Uri pCloudHelp = Uri.parse(
    'https://help.pcloud.com/article/connect-to-pcloud-using-webdav-and-rsync',
  );

  final WebDavSyncConnectController? connectController;
  final WebDavSyncLoginInspector? inspect;
  final WebDavSyncBinding? repairBinding;
  final String? initialUsername;

  @override
  State<WebDavSyncLoginScreen> createState() => _WebDavSyncLoginScreenState();
}

final class _WebDavSyncLoginScreenState extends State<WebDavSyncLoginScreen> {
  final TextEditingController _url = TextEditingController();
  final TextEditingController _username = TextEditingController();
  final TextEditingController _password = TextEditingController();

  WebDavSyncProviderPreset _provider = WebDavSyncProviderPreset.koofr;
  PCloudServerSite _pCloudServerSite = PCloudServerSite.europe;
  String? _error;
  bool _connecting = false;

  bool get _isRepair => widget.repairBinding != null;

  bool get _isInsecure =>
      !_isRepair &&
      _provider == WebDavSyncProviderPreset.custom &&
      WebDavProtocolClient.isInsecureUrl(_url.text);

  @override
  void initState() {
    super.initState();
    _username.text = widget.initialUsername ?? '';
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password
      ..clear()
      ..dispose();
    super.dispose();
  }

  void _changed() {
    setState(() => _error = null);
  }

  Future<void> _connect() async {
    if (_connecting) return;
    final username = _username.text.trim();
    final password = _password.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _error = 'Enter your WebDAV username and password.');
      return;
    }

    late final Uri endpoint;
    try {
      endpoint = _isRepair
          ? widget.repairBinding!.location.endpoint
          : switch (_provider) {
              WebDavSyncProviderPreset.koofr =>
                WebDavSyncLoginScreen.koofrEndpoint,
              WebDavSyncProviderPreset.pCloud =>
                _pCloudServerSite == PCloudServerSite.europe
                    ? WebDavSyncLoginScreen.pCloudEuEndpoint
                    : WebDavSyncLoginScreen.pCloudUsEndpoint,
              WebDavSyncProviderPreset.custom =>
                WebDavProtocolClient.parseEndpoint(_url.text),
            };
    } on Object {
      setState(() => _error = 'Enter a valid HTTP or HTTPS WebDAV server URL.');
      return;
    }

    final result = WebDavSyncLoginCredentials(
      endpoint: endpoint,
      username: username,
      password: password,
      serverName: _isRepair
          ? widget.repairBinding!.location.serverName
          : switch (_provider) {
              WebDavSyncProviderPreset.koofr => 'Koofr',
              WebDavSyncProviderPreset.pCloud => 'pCloud',
              WebDavSyncProviderPreset.custom => endpoint.host,
            },
    );
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await runWebDavForegroundSync<void>(
        context,
        stage: 'Verifying WebDAV account…',
        progressLimit: null,
        operation: (_) async {
          if (widget.inspect case final inspect?) {
            await inspect(result);
          } else if (_isRepair) {
            await widget.connectController!.inspectReconnect(result);
          } else {
            await widget.connectController!.inspect(result);
          }
        },
      );
      if (mounted) Navigator.of(context).pop(result);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = _inlineError(error));
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  static String _inlineError(Object error) {
    if (error is WebDavSyncLegacyRootException) return error.message;
    if (error is WebDavSyncStoreNotLinearizableException) {
      return WebDavSyncStoreNotLinearizableException.userMessage;
    }
    if (error is WebDavSyncSetupInconclusiveException) {
      return WebDavSyncSetupInconclusiveException.userMessage;
    }
    if (error is WebDavException &&
        error.kind == WebDavErrorKind.authentication) {
      return 'WebDAV login failed. Check your username and password.';
    }
    return 'Could not verify this WebDAV account. Check the details and try '
        'again.';
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'WebDAV Sync login',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_isRepair) ...[
                  InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'WebDAV server',
                    ),
                    child: SelectableText(
                      widget.repairBinding!.location.endpoint.toString(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Sync folder: '
                    '${widget.repairBinding!.location.folderPath}',
                  ),
                  const SizedBox(height: 16),
                ] else ...[
                  DropdownButtonFormField<WebDavSyncProviderPreset>(
                    key: const ValueKey('webdav-sync-server'),
                    initialValue: _provider,
                    decoration: const InputDecoration(labelText: 'Server'),
                    items: const [
                      DropdownMenuItem(
                        value: WebDavSyncProviderPreset.koofr,
                        child: Text('Koofr'),
                      ),
                      DropdownMenuItem(
                        value: WebDavSyncProviderPreset.pCloud,
                        child: Text('pCloud'),
                      ),
                      DropdownMenuItem(
                        value: WebDavSyncProviderPreset.custom,
                        child: Text('Custom'),
                      ),
                    ],
                    onChanged: _connecting
                        ? null
                        : (provider) {
                            if (provider == null) return;
                            setState(() {
                              _provider = provider;
                              _error = null;
                            });
                          },
                  ),
                  const SizedBox(height: 16),
                  if (_provider == WebDavSyncProviderPreset.pCloud) ...[
                    DropdownButtonFormField<PCloudServerSite>(
                      key: const ValueKey('pcloud-server-site'),
                      initialValue: _pCloudServerSite,
                      decoration: const InputDecoration(
                        labelText: 'Server site',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: PCloudServerSite.europe,
                          child: Text('Europe'),
                        ),
                        DropdownMenuItem(
                          value: PCloudServerSite.unitedStates,
                          child: Text('United States'),
                        ),
                      ],
                      onChanged: _connecting
                          ? null
                          : (site) {
                              if (site == null) return;
                              setState(() {
                                _pCloudServerSite = site;
                                _error = null;
                              });
                            },
                    ),
                    const SizedBox(height: 16),
                  ],
                ],
                if (!_isRepair &&
                    _provider == WebDavSyncProviderPreset.koofr) ...[
                  const Text(
                    'Koofr needs an app password — Koofr → Settings → '
                    'Password → App passwords. Your username is your Koofr '
                    'email.',
                  ),
                  const SizedBox(height: 16),
                ] else if (!_isRepair &&
                    _provider == WebDavSyncProviderPreset.pCloud) ...[
                  const Text(
                    'Connect with your pCloud account email and password. '
                    'Choose the region where your pCloud account stores its '
                    'data. If two-factor authentication is enabled, pCloud '
                    'may ask you to approve the connection by email.',
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('pcloud-official-help'),
                      onPressed: _connecting
                          ? null
                          : () => launchUrl(
                              WebDavSyncLoginScreen.pCloudHelp,
                              mode: LaunchMode.externalApplication,
                            ),
                      icon: const Icon(Icons.open_in_new_rounded),
                      label: const Text('Open official pCloud WebDAV help'),
                    ),
                  ),
                  const SizedBox(height: 8),
                ] else if (!_isRepair) ...[
                  TvTextField(
                    key: const ValueKey('webdav-sync-url'),
                    controller: _url,
                    enabled: !_connecting,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'WebDAV server URL',
                      hintText: 'https://example.com/dav/',
                    ),
                    onChanged: (_) => _changed(),
                  ),
                  if (_isInsecure) ...[
                    const SizedBox(height: 8),
                    const Text(
                      'Warning: http:// sends your WebDAV password without '
                      'transport encryption.',
                      style: TextStyle(color: Colors.amber),
                    ),
                  ],
                  const SizedBox(height: 16),
                ],
                TvTextField(
                  key: const ValueKey('webdav-sync-username'),
                  controller: _username,
                  enabled: !_connecting,
                  autofocus: true,
                  decoration: InputDecoration(
                    labelText:
                        !_isRepair &&
                            _provider == WebDavSyncProviderPreset.koofr
                        ? 'Koofr email'
                        : !_isRepair &&
                              _provider == WebDavSyncProviderPreset.pCloud
                        ? 'pCloud email'
                        : 'WebDAV username',
                  ),
                  onChanged: (_) => _changed(),
                ),
                const SizedBox(height: 16),
                TvTextField(
                  key: const ValueKey('webdav-sync-password'),
                  controller: _password,
                  enabled: !_connecting,
                  obscureText: true,
                  textInputAction: TextInputAction.done,
                  keyboardSubmitLabel: 'Connect',
                  decoration: InputDecoration(
                    labelText:
                        !_isRepair &&
                            _provider == WebDavSyncProviderPreset.koofr
                        ? 'Koofr app password'
                        : !_isRepair &&
                              _provider == WebDavSyncProviderPreset.pCloud
                        ? 'pCloud password'
                        : 'WebDAV password',
                  ),
                  onChanged: (_) => _changed(),
                  onSubmitted: (_) => _connect(),
                ),
                if (_error case final error?) ...[
                  const SizedBox(height: 12),
                  Text(error, style: const TextStyle(color: Colors.redAccent)),
                ],
                const SizedBox(height: 20),
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton(
                    onPressed: _connecting ? null : _connect,
                    child: _connecting
                        ? const SizedBox.square(
                            dimension: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Connect'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
