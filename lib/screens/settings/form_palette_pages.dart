import 'package:flutter/material.dart';
import '../../theme/app_looks.dart';
import '../../theme/app_theme.dart';
import '../../theme/app_theme_controller.dart';
import '../../theme/app_theme_scope.dart';
import '../../theme/shipped_themes.dart' show kDetailThemesShipped;
import '../../utils/platform_util.dart';
import '../../widgets/detail/theme/detail_themes.dart';
import 'widgets/settings_widgets.dart';

/// Shared TV entry-focus idiom for the two pickers below.
mixin _FirstRowFocus<T extends StatefulWidget> on State<T> {
  final FocusNode firstCardMarker = FocusNode(
    skipTraversal: true,
    canRequestFocus: false,
  );

  void focusFirstRowOnTv() {
    if (!PlatformUtil.isTelevision) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final primary = FocusManager.instance.primaryFocus;
      if (primary != null && primary is! FocusScopeNode) return;
      firstCardMarker.traversalDescendants.firstOrNull?.requestFocus();
    });
  }

  @override
  void dispose() {
    firstCardMarker.dispose();
    super.dispose();
  }
}

/// Appearance → **Form**. Structure only: how panels separate, how artwork
/// is framed, what focus does, how things move. Never changes a colour.
class FormPage extends StatefulWidget {
  const FormPage({super.key});

  @override
  State<FormPage> createState() => _FormPageState();
}

class _FormPageState extends State<FormPage> with _FirstRowFocus {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    focusFirstRowOnTv();
  }

  Future<void> _pick(AppForm form) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await LookParts.applyForm(form);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    final classicPalette = AppThemeController.instance.isLegacy;
    final active = LookParts.activeForm();
    return SettingsPageScaffold(
      title: 'Form',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kSettingsMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SettingsPageHeader(
                  icon: Icons.dashboard_customize_rounded,
                  title: 'Form',
                  subtitle: 'How the app is built — never its colours',
                ),
                const SizedBox(height: 18),
                if (classicPalette)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: SettingsInfoBanner(
                      icon: Icons.info_outline_rounded,
                      text: 'The Nextup Classic palette is hand-built and '
                          'only comes in the Classic form. Pick any other '
                          'palette to use a different form.',
                    ),
                  ),
                Focus(
                  focusNode: firstCardMarker,
                  canRequestFocus: false,
                  skipTraversal: true,
                  child: SettingsSection(
                    title: 'Forms',
                    blurb: 'Panels, artwork framing, focus and motion. Your '
                        'colour palette stays as it is.',
                    children: [
                      for (final f in LookParts.forms)
                        SettingsTile(
                          icon: f.id == active?.id
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded,
                          title: f.label,
                          subtitle: f.blurb,
                          enabled:
                              !classicPalette || f.id == AppThemes.legacyId,
                          trailing: f.id == active?.id
                              ? Icon(Icons.check_rounded,
                                  size: 20, color: app.settings.accent2)
                              : const SizedBox.shrink(),
                          onTap: () => _pick(f),
                        ),
                    ],
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

/// Appearance → **Colour palette**. Colours only: grounds, panels, accent,
/// focus. Never changes the form.
class PalettePage extends StatefulWidget {
  const PalettePage({super.key});

  @override
  State<PalettePage> createState() => _PalettePageState();
}

class _PalettePageState extends State<PalettePage> with _FirstRowFocus {
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    focusFirstRowOnTv();
  }

  Future<void> _pick(LookPalette p) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await LookParts.applyPalette(p);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  List<Color> _swatches(String themeId) {
    if (themeId == AppThemes.legacyId) {
      final l = AppThemes.legacy;
      return [l.home.bg, l.settings.panel, l.settings.accent, l.home.chromeAccent];
    }
    final t = DetailThemes.byId(themeId);
    return [t.ground, t.panel, t.accent, t.focus];
  }

  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    final palettes = LookParts.palettes([
      for (final t in DetailThemes.catalogue)
        if (kDetailThemesShipped.contains(t.id)) (id: t.id, label: t.label),
    ]);
    return SettingsPageScaffold(
      title: 'Colour palette',
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kSettingsMaxWidth),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SettingsPageHeader(
                  icon: Icons.palette_rounded,
                  title: 'Colour palette',
                  subtitle:
                      'The app\'s colours — the ${LookParts.formLabel()} form '
                      'stays as it is',
                ),
                const SizedBox(height: 18),
                Focus(
                  focusNode: firstCardMarker,
                  canRequestFocus: false,
                  skipTraversal: true,
                  child: SettingsSection(
                    title: 'Palettes',
                    blurb: 'Background · panel · accent · focus',
                    children: [
                      for (final p in palettes)
                        SettingsTile(
                          icon: p.isActive
                              ? Icons.radio_button_checked_rounded
                              : Icons.radio_button_unchecked_rounded,
                          title: p.label,
                          subtitle: p.themeId == AppThemes.legacyId
                              ? 'The original colours — Classic form only'
                              : 'Colours only',
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              for (final c in _swatches(p.themeId))
                                Container(
                                  width: 14,
                                  height: 14,
                                  margin: const EdgeInsets.only(left: 4),
                                  decoration: BoxDecoration(
                                    color: c,
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: app.fade(app.core.tx, 0.25),
                                    ),
                                  ),
                                ),
                              const SizedBox(width: 10),
                              p.isActive
                                  ? Icon(Icons.check_rounded,
                                      size: 20, color: app.settings.accent2)
                                  : const SizedBox(width: 20),
                            ],
                          ),
                          onTap: () => _pick(p),
                        ),
                    ],
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
