import 'package:flutter/material.dart';

import '../../services/storage_service.dart';
import 'filter_settings_page.dart';
import 'widgets/settings_widgets.dart';

/// Settings → Downloads → Download button: what a title's Download button
/// does. The same two choices the button's own sheet offers.
class DownloadSettingsPage extends StatefulWidget {
  const DownloadSettingsPage({super.key});

  @override
  State<DownloadSettingsPage> createState() => _DownloadSettingsPageState();
}

class _DownloadSettingsPageState extends State<DownloadSettingsPage> {
  bool _loading = true;
  bool _alwaysAsk = true;
  String _mode = 'manual';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final alwaysAsk = await StorageService.getDownloadButtonAlwaysAsk();
    final mode = await StorageService.getDownloadButtonMode();
    if (!mounted) return;
    setState(() {
      _alwaysAsk = alwaysAsk;
      _mode = mode;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Download button',
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                SettingsSection(
                  title: 'When you press Download',
                  children: [
                    SettingsToggleTile(
                      icon: Icons.help_outline_rounded,
                      title: 'Always ask',
                      subtitle: 'Choose automatic or manual every time',
                      value: _alwaysAsk,
                      onChanged: (value) {
                        setState(() => _alwaysAsk = value);
                        StorageService.setDownloadButtonAlwaysAsk(value);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                SettingsSection(
                  title: _alwaysAsk ? 'Last choice' : 'Download',
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SettingsSelectDropdown(
                        value: _mode,
                        options: const [
                          SettingsSelectOption(
                            'auto',
                            'Automatically',
                            'Downloads the best source matching your saved '
                                'filters. If none matches, the source list '
                                'opens.',
                          ),
                          SettingsSelectOption(
                            'manual',
                            'Choose a source',
                            'Opens the source list so you pick one.',
                          ),
                        ],
                        onChanged: (value) {
                          setState(() => _mode = value);
                          StorageService.setDownloadButtonMode(value);
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                SettingsSection(
                  title: 'Saved filters',
                  children: [
                    SettingsTile(
                      icon: Icons.tune_rounded,
                      title: 'Filters',
                      subtitle:
                          'Quality, source, language, codec — kept from your '
                          'last source search',
                      onTap: () =>
                          pushSettingsPage(context, const FilterSettingsPage()),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                SettingsInfoBanner(
                  text: _alwaysAsk
                      ? 'The Download button asks each time. Turn off '
                            '"Always ask" in its sheet or here to make the '
                            'choice above the default.'
                      : 'The Download button does the choice above without '
                            'asking.',
                ),
              ],
            ),
    );
  }
}
