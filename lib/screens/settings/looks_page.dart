import 'package:flutter/material.dart';

import '../../services/analytics_service.dart';
import '../../theme/app_looks.dart';
import '../../theme/app_theme_controller.dart';
import '../../theme/app_theme_scope.dart';
import '../../utils/platform_util.dart';
import 'form_palette_pages.dart';
import 'theme_tokens_page.dart';
import 'widgets/settings_widgets.dart';

/// Appearance → **Looks**.
///
/// The two independent choices first — **Form** (how the app is built) and
/// **Colour palette** (its colours) — then **Presets**, which set both plus
/// the layouts in one pick. Changing either choice afterwards simply moves
/// the preset tick away; nothing else is touched.
class LooksPage extends StatefulWidget {
  const LooksPage({super.key});

  @override
  State<LooksPage> createState() => _LooksPageState();
}

class _LooksPageState extends State<LooksPage> {
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

  Future<void> _apply(AppLook look) async {
    if (_applying) return;
    setState(() => _applying = true);
    await AppThemeController.instance.clearOverrides();
    await LookApplier.apply(look);
    if (!mounted) return;
    setState(() => _applying = false);
  }

  Future<void> _open(Widget page) async {
    await pushSettingsPage(context, page);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    final edits = AppThemeController.instance.overrides.count;
    final active = edits == 0 ? AppLooks.active() : null;
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
                  subtitle: 'Form and colour are separate choices',
                ),
                const SizedBox(height: 18),
                Focus(
                  focusNode: _firstCardMarker,
                  canRequestFocus: false,
                  skipTraversal: true,
                  child: SettingsSection(
                    title: 'Your look',
                    blurb: 'Change either one — the other stays as it is.',
                    children: [
                      SettingsTile(
                        icon: Icons.dashboard_customize_rounded,
                        title: 'Form',
                        subtitle: '${LookParts.formLabel()} — panels, artwork '
                            'framing, focus and motion',
                        onTap: () => _open(const FormPage()),
                      ),
                      SettingsTile(
                        icon: Icons.palette_rounded,
                        title: 'Colour palette',
                        subtitle:
                            '${LookParts.paletteLabel(AppThemeController.instance.id)}'
                            ' — background, panels, accent and focus',
                        onTap: () => _open(const PalettePage()),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 18),
                SettingsSection(
                  title: 'Presets',
                  blurb: 'Sets a form, a palette and the page layouts in one '
                      'pick.',
                  children: [
                    for (final look in AppLooks.all)
                      SettingsTile(
                        icon: look.id == active?.id
                            ? Icons.radio_button_checked_rounded
                            : Icons.radio_button_unchecked_rounded,
                        title: look.label,
                        subtitle: '${_formOf(look)} form · '
                            '${LookParts.paletteLabel(look.values['app_theme'] ?? 'legacy')} '
                            'palette — ${look.blurb}',
                        trailing: look.id == active?.id
                            ? Icon(Icons.check_rounded,
                                size: 20, color: app.settings.accent2)
                            : const SizedBox.shrink(),
                        onTap: () => _apply(look),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                SettingsSection(
                  title: '',
                  children: [
                    SettingsTile(
                      icon: Icons.tune_rounded,
                      title: 'Advanced',
                      subtitle: edits == 0
                          ? 'Edit individual tokens — colour, shape, motion'
                          : '$edits ${edits == 1 ? "token" : "tokens"} '
                              'changed on top of your look',
                      onTap: () => _open(const ThemeTokensPage()),
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

  static String _formOf(AppLook look) {
    final id = look.values['app_structure'] ?? 'legacy';
    for (final f in LookParts.forms) {
      if (f.id == id) return f.label;
    }
    return 'Classic';
  }
}
