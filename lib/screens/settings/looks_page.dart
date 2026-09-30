import 'package:flutter/material.dart';

import '../../services/analytics_service.dart';
import '../../theme/app_looks.dart';
import '../../theme/app_theme.dart';
import '../../theme/app_theme_controller.dart';
import '../../theme/app_theme_scope.dart';
import '../../theme/shipped_themes.dart' show kDetailThemesShipped;
import '../../utils/platform_util.dart';
import '../../widgets/detail/theme/detail_themes.dart';
import 'theme_tokens_page.dart';
import 'widgets/settings_widgets.dart';

/// Appearance → **Looks**, as two independent picks.
///
///  * **Structure** — the app's form: corners, type, artwork framing, the
///    focus expression, motion and surfaces, plus the Look's layouts (details
///    page, launch ident, TV and desktop chrome). Never touches colour.
///  * **Colour palette** — the app's colours (and, for the curated palettes,
///    the text brightness they were tuned for). Never touches form.
///
/// Either can change without moving the other; every individual picker is
/// still where it was, and Advanced still layers token edits over both.
class LooksPage extends StatefulWidget {
  const LooksPage({super.key});

  @override
  State<LooksPage> createState() => _LooksPageState();
}

class _LooksPageState extends State<LooksPage> {
  /// Non-focusable marker around the first card; on TV it hands entry focus
  /// to the first option row. Same idiom as the other Appearance pickers.
  final FocusNode _firstCardMarker = FocusNode(
    debugLabel: 'looks-first-card',
    skipTraversal: true,
    canRequestFocus: false,
  );

  bool _applying = false;

  @override
  void initState() {
    super.initState();
    AnalyticsService.screenView('looks_settings');
    if (PlatformUtil.isTelevision) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final primary = FocusManager.instance.primaryFocus;
        if (primary != null && primary is! FocusScopeNode) return;
        _firstCardMarker.traversalDescendants.firstOrNull?.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _firstCardMarker.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_applying) return;
    setState(() => _applying = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  List<Color> _swatchesFor(String themeId) {
    if (themeId == AppThemes.legacyId) {
      final l = AppThemes.legacy;
      return [l.home.bg, l.settings.panel, l.settings.accent, l.home.chromeAccent];
    }
    final t = DetailThemes.byId(themeId);
    return [t.ground, t.panel, t.accent, t.focus];
  }

  static const Map<String, String> _inkLabels = {
    'bright': 'Bright text',
    'soft': 'Soft text',
    'dim': 'Dim text',
  };

  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    final controller = AppThemeController.instance;
    final edits = controller.overrides.count;
    final classicPalette = controller.isLegacy;
    final activeStructure = LookParts.activeStructure();
    final shipped = [
      for (final t in DetailThemes.catalogue)
        if (kDetailThemesShipped.contains(t.id)) (id: t.id, label: t.label),
    ];
    final more = LookParts.morePalettes(shipped);

    Widget check(bool on) => on
        ? Icon(Icons.check_rounded, size: 20, color: app.settings.accent2)
        : const SizedBox(width: 20);

    Widget swatches(String themeId, bool on) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final c in _swatchesFor(themeId))
          Container(
            width: 14,
            height: 14,
            margin: const EdgeInsets.only(left: 4),
            decoration: BoxDecoration(
              color: c,
              shape: BoxShape.circle,
              border: Border.all(color: app.fade(app.core.tx, 0.25)),
            ),
          ),
        const SizedBox(width: 10),
        check(on),
      ],
    );

    Widget paletteTile(LookPalette p, {String? subtitle}) {
      final on = p.isActive;
      return SettingsTile(
        icon: on
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_unchecked_rounded,
        title: p.label,
        subtitle: subtitle ??
            (p.textBrightness == null
                ? 'Colours only'
                : 'Colours · ${_inkLabels[p.textBrightness] ?? p.textBrightness}'),
        trailing: swatches(p.themeId, on),
        onTap: () => _run(() => LookParts.applyPalette(p)),
      );
    }

    return SettingsPageScaffold(
      title: 'Looks',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kSettingsMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SettingsPageHeader(
                  icon: Icons.auto_awesome_rounded,
                  title: 'Looks',
                  subtitle: 'Pick the structure and the colour palette separately',
                ),
                const SizedBox(height: 18),
                if (edits > 0)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: SettingsInfoBanner(
                      icon: Icons.tune_rounded,
                      text: '$edits ${edits == 1 ? "token" : "tokens"} edited '
                          'under Advanced still apply on top of the structure '
                          'and palette below.',
                    ),
                  ),

                // ── Structure ────────────────────────────────────────────
                Focus(
                  focusNode: _firstCardMarker,
                  canRequestFocus: false,
                  skipTraversal: true,
                  child: SettingsSection(
                    title: 'Structure',
                    blurb: classicPalette
                        ? 'The Debrify Classic palette is hand-built with its '
                            'own form. Pick another palette to change the '
                            'structure.'
                        : 'Form and layout — corners, type, artwork framing, '
                            'focus, motion and the page layouts. Your colours '
                            'stay as they are.',
                    children: [
                      for (final s in LookParts.structures)
                        SettingsTile(
                          icon: s.id == activeStructure?.id
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded,
                          title: s.label,
                          subtitle: s.blurb,
                          enabled: !classicPalette || s.themeId == AppThemes.legacyId,
                          trailing: check(s.id == activeStructure?.id),
                          onTap: () => _run(() => LookParts.applyStructure(s)),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),

                // ── Colour palette ───────────────────────────────────────
                SettingsSection(
                  title: 'Colour palette',
                  blurb: 'Colours only — grounds, panels, accent and focus. '
                      'Your structure and layouts stay as they are.',
                  children: [
                    for (final p in LookParts.curatedPalettes) paletteTile(p),
                  ],
                ),
                const SizedBox(height: 14),
                SettingsSection(
                  title: 'More palettes',
                  children: [
                    for (final p in more) paletteTile(p, subtitle: 'Colours only'),
                  ],
                ),
                const SizedBox(height: 18),
                SettingsSection(
                  title: '',
                  children: [
                    SettingsTile(
                      icon: Icons.tune_rounded,
                      title: 'Advanced',
                      subtitle: edits == 0
                          ? 'Edit individual tokens — colour, shape, motion'
                          : '$edits ${edits == 1 ? "token" : "tokens"} '
                              'changed on top of your picks',
                      onTap: () async {
                        await pushSettingsPage(
                          context,
                          const ThemeTokensPage(),
                        );
                        if (mounted) setState(() {});
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
