import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/downloads/download_preferences.dart';
import '../../services/downloads/download_request.dart';
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
  DownloadPreferences _prefs = const DownloadPreferences();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await DownloadPreferences.load();
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      _loading = false;
    });
  }

  void _update(DownloadPreferences next) {
    setState(() => _prefs = next);
    unawaited(next.save());
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
                      value: _prefs.alwaysAsk,
                      onChanged: (value) =>
                          _update(_prefs.copyWith(alwaysAsk: value)),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                SettingsSection(
                  title: _prefs.alwaysAsk ? 'Last choice' : 'Download',
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SettingsSelectDropdown(
                        value: _prefs.choice.name,
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
                        onChanged: (value) => _update(
                          _prefs.copyWith(
                            choice: DownloadChoice.values.byName(value),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                SettingsSection(
                  title: 'For series',
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: SettingsSelectDropdown(
                        value: _prefs.seriesScope.name,
                        options: [
                          const SettingsSelectOption(
                            'episode',
                            'This episode',
                            'The episode Play would open.',
                          ),
                          SettingsSelectOption(
                            'nextEpisodes',
                            'Next $kNextEpisodesCount episodes',
                            'Starting with the one Play would open — good '
                                'for a trip.',
                          ),
                          const SettingsSelectOption(
                            'season',
                            'Whole season',
                            'Every episode of the season.',
                          ),
                        ],
                        onChanged: (value) => _update(
                          _prefs.copyWith(
                            seriesScope: DownloadScope.values.byName(value),
                          ),
                        ),
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
                  text: _prefs.alwaysAsk
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
