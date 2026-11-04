import 'package:flutter/material.dart';
import '../../services/storage_service.dart';
import '../../theme/app_theme_scope.dart';
import '../../theme/theme_palette.dart';
import '../../utils/platform_util.dart';
import 'widgets/settings_widgets.dart';

/// One selectable option in any of the three dock sections.
class PlayerDockChoice {
  final String value;
  final String label;
  final String subtitle;
  const PlayerDockChoice(this.value, this.label, this.subtitle);
}

/// The three genuinely different looks. Adaptive, Compact, Two-Tier and
/// Cinema Bar are one dock in four arrangements, so they live under
/// [kPlayerDockLayoutChoices] rather than posing as separate styles.
const List<PlayerDockChoice> kPlayerDockStyleChoices = [
  PlayerDockChoice(
    'glass',
    'Glass',
    'Minimal frosted controls: play in the middle, one panel below',
  ),
  PlayerDockChoice(
    'dock',
    'Dock',
    'Every tool on screen, in your accent colour',
  ),
  PlayerDockChoice(
    'classic',
    'Classic',
    'The original row of labelled buttons',
  ),
];

/// How the Dock arranges itself. Stored as the `player_dock_style` value.
///
/// Only two real choices: Automatic already picks the one-row, two-row or
/// wide-bar arrangement from the window size, so forcing two-row or wide is
/// not offered. Installs that stored `tiers` / `cinema` keep them (the player
/// still honours both) and show here as Automatic.
const List<PlayerDockChoice> kPlayerDockLayoutChoices = [
  PlayerDockChoice(
    'auto',
    'Automatic',
    'One row on phones, a fuller bar on bigger screens',
  ),
  PlayerDockChoice('compact', 'Compact', 'Always one row, the rest under More'),
];

/// Stored `player_dock_style` values that mean "the Dock".
bool isPlayerDockLayout(String style) => const {
  'auto',
  'compact',
  'tiers',
  'cinema',
  'two_tier',
}.contains(style);

/// The Layout radio a stored Dock value belongs to.
String playerDockLayoutGroup(String style) =>
    style == 'compact' ? 'compact' : 'auto';

/// The Style radio a stored value belongs to.
String playerDockStyleGroup(String style) =>
    isPlayerDockLayout(style) ? 'dock' : style;

const List<PlayerDockChoice> kPlayerDockPaletteChoices = [
  PlayerDockChoice('app', 'App colour', 'Follows your colour palette'),
  PlayerDockChoice('custom', 'Manual colour', 'Detached from the app — pick one below'),
  PlayerDockChoice(
    'ultraviolet',
    'Ultraviolet',
    'Hot magenta into deep violet',
  ),
  PlayerDockChoice('crimson', 'Crimson', 'Scarlet into oxblood'),
  PlayerDockChoice('aurum', 'Aurum', 'Champagne into old brass'),
  PlayerDockChoice('ice', 'Ice', 'Electric cyan into deep blue'),
];

const List<PlayerDockChoice> kPlayerDockSizeChoices = [
  PlayerDockChoice('auto', 'Auto', 'Follows the screen — recommended'),
  PlayerDockChoice('small', 'Small', 'Compact controls on every screen'),
  PlayerDockChoice('medium', 'Medium', 'Fixed, slightly larger'),
  PlayerDockChoice('large', 'Large', 'Fixed, largest — easiest to hit'),
];

/// Row caption for the Appearance list — the chosen style, plus the palette
/// when one is actually in effect.
String playerDockLabel(String style, String palette, [String size = 'auto']) {
  final group = playerDockStyleGroup(style);
  String labelOf(List<PlayerDockChoice> list, String value) => list
      .firstWhere((c) => c.value == value, orElse: () => list.first)
      .label;
  final styleLabel = labelOf(kPlayerDockStyleChoices, group);
  if (group != 'dock') return styleLabel;
  final layout = playerDockLayoutGroup(style);
  return [
    styleLabel,
    if (layout != 'auto') labelOf(kPlayerDockLayoutChoices, layout),
    labelOf(kPlayerDockPaletteChoices, palette),
    if (size != 'auto') labelOf(kPlayerDockSizeChoices, size),
  ].join(' · ');
}

/// Player control style, colour and size (`player_dock_style`,
/// `player_dock_palette`, `player_dock_size`).
///
/// Three sections on one page rather than three Appearance rows: the section
/// is already long, and the three prefs are one decision.
///
/// Layout, colour and size only exist for the Dock, so they only show while
/// it is selected. Their stored values survive a round trip through Glass or
/// Classic.
///
/// The dock reads all three once at launch, so a change applies to the next
/// playback session; persist-on-tap is all that is needed.
class PlayerDockPage extends StatefulWidget {
  const PlayerDockPage({super.key});

  @override
  State<PlayerDockPage> createState() => _PlayerDockPageState();
}

class _PlayerDockPageState extends State<PlayerDockPage> {
  bool _loading = true;
  String _style = 'glass';
  String _palette = 'ultraviolet';
  String _size = 'auto';

  /// Non-focusable marker around the first options card; used on TV to hand
  /// entry focus to its first focusable descendant.
  final FocusNode _firstCardMarker = FocusNode(
    debugLabel: 'player-dock-first-card',
    skipTraversal: true,
    canRequestFocus: false,
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _firstCardMarker.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final style = await StorageService.getPlayerDockStyle();
    final palette = await StorageService.getPlayerDockPalette();
    final size = await StorageService.getPlayerDockSize();
    final swatch = await StorageService.getPlayerDockCustomSwatch();
    if (!mounted) return;
    setState(() {
      _style = style;
      if (isPlayerDockLayout(style)) {
        _lastLayout = playerDockLayoutGroup(style);
      }
      _palette = palette;
      _customSwatch = swatch;
      _size = size;
      _loading = false;
    });
    if (PlatformUtil.isAndroidTvCached) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final primary = FocusManager.instance.primaryFocus;
        if (primary != null && primary is! FocusScopeNode) return;
        _firstCardMarker.traversalDescendants.firstOrNull?.requestFocus();
      });
    }
  }

  /// Remembered Dock layout, so Glass → Dock returns to the last layout.
  String _lastLayout = 'auto';

  Future<void> _selectStyle(String group) async {
    if (group == playerDockStyleGroup(_style)) return;
    final value = group == 'dock' ? _lastLayout : group;
    setState(() => _style = value);
    await StorageService.setPlayerDockStyle(value);
  }

  Future<void> _selectLayout(String value) async {
    if (value == _layout) return;
    setState(() {
      _style = value;
      _lastLayout = value;
    });
    await StorageService.setPlayerDockStyle(value);
  }

  Future<void> _selectPalette(String value) async {
    if (value == _palette) return;
    setState(() => _palette = value);
    await StorageService.setPlayerDockPalette(value);
  }

  String? _customSwatch;

  Future<void> _selectSwatch(String id) async {
    setState(() {
      _customSwatch = id;
      _palette = 'custom';
    });
    await StorageService.setPlayerDockCustomSwatch(id);
    await StorageService.setPlayerDockPalette('custom');
  }

  /// The colour a palette row stands for, for its trailing dot.
  Color? _dotFor(String value) => switch (value) {
    'app' => StorageService.appAccentArgb == null
        ? null
        : Color(StorageService.appAccentArgb!),
    'custom' => ThemePalette.colorOf(_customSwatch),
    'ultraviolet' => const Color(0xFFB03CFF),
    'crimson' => const Color(0xFFE0243A),
    'aurum' => const Color(0xFFE0B04A),
    'ice' => const Color(0xFF3AA8FF),
    _ => null,
  };

  Widget _swatchGrid() {
    final t = AppThemeScope.of(context).settings;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final sw in ThemePalette.all)
            Tooltip(
              message: sw.label,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _styled ? () => _selectSwatch(sw.id) : null,
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: sw.color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: _customSwatch == sw.id && _palette == 'custom'
                          ? t.accent2
                          : const Color(0x33FFFFFF),
                      width: _customSwatch == sw.id && _palette == 'custom'
                          ? 3
                          : 1,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _selectSize(String value) async {
    if (value == _size) return;
    setState(() => _size = value);
    await StorageService.setPlayerDockSize(value);
  }

  /// Layout, colour and size only apply to the Dock.
  bool get _styled => isPlayerDockLayout(_style);

  String get _layout => playerDockLayoutGroup(_style);

  @override
  Widget build(BuildContext context) {
    final t = AppThemeScope.of(context).settings;
    if (_loading) {
      return const SettingsPageScaffold(
        title: 'Player Controls',
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return SettingsPageScaffold(
      title: 'Player Controls',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kSettingsMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SettingsPageHeader(
                  icon: Icons.tune_rounded,
                  title: 'Player Controls',
                  subtitle:
                      'The on-screen controls during playback — their layout, '
                      'accent colour and size',
                ),
                const SizedBox(height: 24),
                Focus(
                  focusNode: _firstCardMarker,
                  canRequestFocus: false,
                  skipTraversal: true,
                  child: SettingsSection(
                    title: 'Style',
                    children: [
                      for (final choice in kPlayerDockStyleChoices)
                        _optionRow(
                          choice,
                          selected: playerDockStyleGroup(_style),
                          onSelect: _selectStyle,
                        ),
                    ],
                  ),
                ),
                if (_styled) ...[
                  const SizedBox(height: 20),
                  SettingsSection(
                    title: 'Layout',
                    children: [
                      for (final choice in kPlayerDockLayoutChoices)
                        _optionRow(
                          choice,
                          selected: _layout,
                          onSelect: _selectLayout,
                        ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SettingsSection(
                    title: 'Colour',
                    blurb: 'App colour follows your colour palette. Manual '
                        'colour detaches the player so it keeps its own.',
                    children: [
                      for (final choice in kPlayerDockPaletteChoices)
                        _optionRow(
                          choice,
                          selected: _palette,
                          onSelect: (v) async {
                            if (v == 'custom' && _customSwatch == null) {
                              // No manual colour picked yet: start from the
                              // first swatch, then the grid below takes over.
                              await _selectSwatch(ThemePalette.all.first.id);
                              return;
                            }
                            await _selectPalette(v);
                          },
                          dot: _dotFor(choice.value),
                        ),
                    ],
                  ),
                  if (_palette == 'custom') _swatchGrid(),
                  const SizedBox(height: 20),
                  SettingsSection(
                    title: 'Size',
                    children: [
                      for (final choice in kPlayerDockSizeChoices)
                        _optionRow(
                          choice,
                          selected: _size,
                          onSelect: _selectSize,
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 14),
                Text(
                  'Applies to the next playback session. Televisions use '
                  'their own remote-friendly controls and are not affected.',
                  style: TextStyle(fontSize: 12.5, height: 1.45, color: t.dim),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _optionRow(
    PlayerDockChoice choice, {
    required String selected,
    required Future<void> Function(String) onSelect,
    bool enabled = true,
    Color? dot,
  }) {
    final t = AppThemeScope.of(context).settings;
    final bool active = selected == choice.value;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: SettingsTile(
        icon: active
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_unchecked_rounded,
        title: choice.label,
        subtitle: choice.subtitle,
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dot != null)
              Container(
                width: 14,
                height: 14,
                margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(
                  color: dot,
                  shape: BoxShape.circle,
                  border: Border.all(color: const Color(0x33FFFFFF)),
                ),
              ),
            active
                ? Icon(Icons.check_rounded, size: 20, color: t.accent2)
                : const SizedBox(width: 20),
          ],
        ),
        // A disabled row stays focusable and tappable but does nothing:
        // SettingsTile's onTap is non-nullable, and swallowing the tap keeps
        // the DPAD traversal order identical between enabled and disabled
        // states, which a removed row would not.
        onTap: enabled ? () => onSelect(choice.value) : () async {},
      ),
    );
  }
}
