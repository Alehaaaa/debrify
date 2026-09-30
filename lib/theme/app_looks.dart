import 'package:flutter/foundation.dart';

import '../services/main_page_bridge.dart';
import 'shipped_themes.dart' show kDetailThemesShipped;
import '../services/storage_service.dart';
import '../services/text_brightness.dart';
import 'app_theme.dart';
import 'app_theme_controller.dart';
import '../widgets/detail/theme/detail_themes.dart';

/// One preference a Look is allowed to set.
///
/// A narrow adapter over the setter that already owns each key, deliberately
/// NOT a rewrite of `StorageService`. There are ~173 `setX` methods in that
/// file; many have no synchronous mirror at all, and at least one caller
/// persists *before* reflecting on purpose (`iptv_settings_page.dart:464`,
/// because the page it returns to re-reads the pref). Teaching every one of
/// them a new protocol to serve a cosmetic feature would be a much larger and
/// riskier change than the feature is worth.
///
/// So the coordination lives here, over the thirteen keys a Look can name.
@immutable
class LookKey {
  /// Stable id used in a bundle and in the generation map.
  final String id;

  /// Human name, for the "what a Look changes" list in the picker.
  final String label;

  /// The value right now.
  final String Function() read;

  /// Persist, delegating to the setter that owns normalisation.
  final Future<void> Function(String value) write;

  /// The live-apply callback the manual picker for this key fires, if any —
  /// so a Look applies live exactly as a manual change does instead of
  /// needing a restart.
  final void Function()? notify;

  const LookKey({
    required this.id,
    required this.label,
    required this.read,
    required this.write,
    this.notify,
  });
}

/// Every key a Look may set. Anything not here cannot be bundled.
abstract final class LookKeys {
  static final appTheme = LookKey(
    id: 'app_theme',
    label: 'App Theme',
    read: () => StorageService.appThemeCached,
    // Through the CONTROLLER, not the setter: it owns the write-through
    // contract (`detail_theme` first, then `app_theme`, so a crash between
    // them leaves an older-build-consistent view) and its own sequence token.
    // A Look that wrote the two keys itself would have to reimplement both.
    write: (v) => AppThemeController.instance.select(v),
  );

  static final appStructure = LookKey(
    id: 'app_structure',
    label: 'Structure',
    // Effective, not stored: "follow the palette" reads as the palette's own
    // theme, so a structure option can be detected as active without the user
    // ever having picked one.
    read: () => AppThemeController.instance.effectiveStructureId,
    write: (v) => AppThemeController.instance.selectStructure(v),
  );

  static final detailPageStyle = LookKey(
    id: 'detail_page_style',
    label: 'Details Page',
    read: () => StorageService.detailPageStyleCached,
    write: StorageService.setDetailPageStyle,
  );

  static final parentsGuideStyle = LookKey(
    id: 'parents_guide_style',
    label: 'Parents Guide',
    read: () => StorageService.parentsGuideStyleCached,
    write: StorageService.setParentsGuideStyle,
  );

  static final launchAnimation = LookKey(
    id: 'launch_animation',
    label: 'Launch Animation',
    read: () => StorageService.importedLaunchAnimationCached == null
        ? StorageService.launchAnimationCached
        : 'imported:${StorageService.importedLaunchAnimationCached}',
    write: StorageService.setLaunchAnimation,
  );

  static final launchIdentPalette = LookKey(
    id: 'launch_ident_palette',
    label: 'Ident Colour',
    read: () => StorageService.launchIdentPaletteCached,
    write: StorageService.setLaunchIdentPalette,
  );

  static final phoneNavStyle = LookKey(
    id: 'phone_nav_style',
    label: 'Phone Navigation',
    read: () => MainPageBridge.phoneNavStyleCached,
    write: (v) async {
      // This one's mirror lives on the bridge, not on StorageService, and the
      // shell reads it synchronously — so it is published before the await
      // for the same reason every other mirror here is.
      MainPageBridge.phoneNavStyleCached = v;
      await StorageService.setPhoneNavStyle(v);
    },
  );

  static final tvHomeStyle = LookKey(
    id: 'tv_home_style',
    label: 'TV Home Layout',
    read: () => StorageService.tvHomeStyleCached,
    write: StorageService.setTvHomeStyle,
    notify: () => MainPageBridge.tvHomeStyleChanged?.call(),
  );

  static final tvSidebarStyle = LookKey(
    id: 'tv_sidebar_style',
    label: 'TV Sidebar',
    read: () => StorageService.tvSidebarStyleCached,
    write: StorageService.setTvSidebarStyle,
    notify: () => MainPageBridge.tvSidebarStyleChanged?.call(),
  );

  static final desktopSidebarStyle = LookKey(
    id: 'desktop_sidebar_style',
    label: 'Desktop Sidebar',
    read: () => StorageService.desktopSidebarStyleCached,
    write: StorageService.setDesktopSidebarStyle,
  );

  static final discoverLayout = LookKey(
    id: 'discover_layout',
    label: 'Discover Layout',
    read: () => StorageService.discoverLayoutCached,
    write: StorageService.setDiscoverLayout,
    notify: () => MainPageBridge.discoverLayoutChanged?.call(),
  );

  static final iptvStyle = LookKey(
    id: 'iptv_style',
    label: 'Live TV Style',
    read: () => StorageService.iptvStyleCached,
    write: StorageService.setIptvStyle,
  );

  static final debrifyTvStyle = LookKey(
    id: 'debrify_tv_style',
    label: 'Debrify TV',
    read: () => StorageService.debrifyTvStyleCached,
    write: StorageService.setDebrifyTvStyle,
    // No notify, like iptv_style: tabs are keyed by index and rebuilt on
    // switch, so the page re-reads the pref in initState.
  );

  static final textBrightness = LookKey(
    id: 'text_brightness',
    label: 'Text Brightness',
    read: () => TextBrightnessController.current.name,
    write: (v) => TextBrightnessController.select(
      TextBrightness.values.firstWhere(
        (b) => b.name == v,
        orElse: () => TextBrightness.bright,
      ),
    ),
  );

  static final List<LookKey> all = [
    appTheme,
    appStructure,
    detailPageStyle,
    parentsGuideStyle,
    launchAnimation,
    launchIdentPalette,
    phoneNavStyle,
    tvHomeStyle,
    tvSidebarStyle,
    desktopSidebarStyle,
    discoverLayout,
    iptvStyle,
    debrifyTvStyle,
    textBrightness,
  ];

  static LookKey? byId(String id) {
    for (final k in all) {
      if (k.id == id) return k;
    }
    return null;
  }
}

/// A curated bundle: one pick instead of fourteen.
///
/// Appearance and Home & Display expose fourteen independent style pickers.
/// Nobody assembles a coherent look out of fourteen dropdowns — they change
/// one, the rest stay where they were, and the app reads half-designed. A Look
/// is the entry point those pickers are alternatives to, and every one of them
/// stays exactly where it is for people who want to tinker.
@immutable
class AppLook {
  final String id;
  final String label;

  /// One line on what it is FOR, not what it sets — the settings list already
  /// says what it sets.
  final String blurb;

  /// Only the keys this Look has an opinion about. A Look that says nothing
  /// about TV render quality leaves it alone.
  final Map<String, String> values;

  const AppLook({
    required this.id,
    required this.label,
    required this.blurb,
    required this.values,
  });

  /// True when every key this Look names already holds its value.
  ///
  /// **Detection, not storage.** "Which Look am I on" is computed rather than
  /// remembered, so a Look can never go stale against a manual change: touch
  /// one picker afterwards and the answer becomes [kCustom] by itself, with
  /// nothing to keep in sync and no way for the stored answer to lie.
  /// [isActive] without the `detail_theme` mirror check — for bundles that
  /// name no `app_theme` (a structure alone).
  bool get isActiveIgnoringMirror {
    for (final entry in values.entries) {
      final key = LookKeys.byId(entry.key);
      if (key == null || key.read() != entry.value) return false;
    }
    return true;
  }

  bool get isActive {
    for (final entry in values.entries) {
      final key = LookKeys.byId(entry.key);
      if (key == null) return false;
      if (key.read() != entry.value) return false;
    }
    // The `detail_theme` MIRROR is not one of the named keys — the controller
    // writes it as part of `app_theme` — so without this a Look reports itself
    // active while the details page renders a palette the user changed by
    // hand. Detection only; `apply` still never writes the mirror itself.
    final theme = values['app_theme'];
    if (theme != null &&
        theme != AppThemes.legacyId &&
        StorageService.detailThemeCached != theme) {
      return false;
    }
    return true;
  }
}

/// What the picker shows when no bundle matches.
const String kCustomLookId = 'custom';

abstract final class AppLooks {
  /// The shipped bundles.
  ///
  /// Each is an art direction rather than a random assortment: the theme, the
  /// layouts and the ident are picked to agree with each other, which is the
  /// whole difference between this and setting fourteen things by hand.
  ///
  /// **No bundle may name a theme outside `kDetailThemesShipped`.** Broadsheet
  /// and Concrete are withheld because screens still carrying hardcoded light
  /// ink render unreadably on them; a Look naming one would walk straight
  /// around that gate. `AppLooks.validate` enforces it and a test pins it.
  static const List<AppLook> all = [
    AppLook(
      id: 'classic',
      label: 'Debrify Classic',
      blurb: 'The app exactly as it has always looked.',
      values: {
        'app_theme': 'legacy',
        'detail_page_style': 'classic',
        'launch_animation': 'horizon',
        'launch_ident_palette': 'ident',
        'text_brightness': 'bright',
        // Pinned explicitly (they equal the historical defaults): a Classic
        // pick must read as a stored CHOICE, or the defaults-generation
        // migration would treat the absent keys as never-chosen and restyle
        // an app whose user explicitly asked for the classic look.
        'tv_home_style': 'canvas',
        'tv_sidebar_style': 'ghost',
        'desktop_sidebar_style': 'rail',
        // Pinned for Look coherence first, migration second: isActive only
        // checks keys a bundle names, so a Classic that said nothing here
        // would report itself active while Debrify TV drew the Spotlight
        // rail.
        'debrify_tv_style': 'grid',
      },
    ),
    AppLook(
      id: 'spotlight',
      label: 'Spotlight',
      blurb:
          'The tvOS idiom — full-bleed art, borderless focus that lifts '
          'and tilts, and a details page that dissolves into colour.',
      values: {
        'app_theme': 'spotlight',
        'detail_page_style': 'showcase',
        'tv_home_style': 'spotlight',
        'tv_sidebar_style': 'pill',
        'desktop_sidebar_style': 'pill',
        'debrify_tv_style': 'spotlight',
        'text_brightness': 'bright',
      },
    ),
    AppLook(
      id: 'midnight',
      label: 'Midnight Signal',
      blurb: 'Today\'s palette, taken app-wide — dark glass and one gold.',
      values: {
        'app_theme': 'signal',
        'detail_page_style': 'stage',
        'launch_animation': 'horizon',
        'launch_ident_palette': 'theme',
        'tv_home_style': 'canvas',
        'discover_layout': 'stage',
        'text_brightness': 'bright',
      },
    ),
    AppLook(
      id: 'console',
      label: 'Console',
      blurb:
          'Squared, monospaced, technical. Everything reads as an instrument.',
      values: {
        'app_theme': 'blueprint',
        'detail_page_style': 'console',
        'launch_animation': 'blueprint',
        'launch_ident_palette': 'theme',
        'iptv_style': 'console',
        'tv_home_style': 'classic',
        'discover_layout': 'grid',
        'text_brightness': 'bright',
      },
    ),
    AppLook(
      id: 'cinema',
      label: 'Cinema',
      blurb: 'Widescreen and unhurried — grain, deep grounds, room to breathe.',
      values: {
        'app_theme': 'cinemascope',
        'detail_page_style': 'marquee',
        'launch_animation': 'anamorphic',
        'launch_ident_palette': 'theme',
        'tv_home_style': 'canvas',
        'discover_layout': 'stage',
        'text_brightness': 'soft',
      },
    ),
    AppLook(
      id: 'neon',
      label: 'Neon Arcade',
      blurb: 'Saturated, rounded and loud. The one that looks like a game.',
      values: {
        'app_theme': 'aurora',
        'detail_page_style': 'stage',
        'launch_animation': 'neon',
        'launch_ident_palette': 'theme',
        'tv_home_style': 'canvas',
        'discover_layout': 'stage',
        'text_brightness': 'bright',
      },
    ),
    AppLook(
      id: 'quiet',
      label: 'Quiet Hours',
      blurb: 'Low-contrast and calm, for a dark room and a late episode.',
      values: {
        'app_theme': 'obsidian',
        'detail_page_style': 'dossier',
        'launch_animation': 'silk',
        'launch_ident_palette': 'theme',
        'tv_home_style': 'canvas',
        'discover_layout': 'stage',
        'text_brightness': 'dim',
      },
    ),
  ];

  /// The Look currently in effect, or null for "Custom".
  static AppLook? active() {
    for (final look in all) {
      if (look.isActive) return look;
    }
    return null;
  }

  /// Every problem with the shipped bundles, as messages. Empty is good.
  ///
  /// Exists so a test can assert it rather than a reviewer having to notice:
  /// an unknown key silently does nothing, and an unshipped theme silently
  /// defeats the withholding in `kDetailThemesShipped`.
  static List<String> validate() {
    final problems = <String>[];
    for (final look in all) {
      for (final entry in look.values.entries) {
        if (LookKeys.byId(entry.key) == null) {
          problems.add('${look.id}: unknown key "${entry.key}"');
        }
      }
      final theme = look.values['app_theme'];
      if (theme != null &&
          theme != AppThemes.legacyId &&
          !kDetailThemesShipped.contains(theme)) {
        problems.add(
          '${look.id}: app_theme "$theme" is not in kDetailThemesShipped — '
          'a Look must not be a side door around a withheld theme',
        );
      }
    }
    return problems;
  }
}

/// Keys that are COLOUR. Everything else a Look sets is form or layout.
const Set<String> _paletteKeys = {'app_theme', 'text_brightness', 'launch_ident_palette'};

/// Appearance → Looks → **Structure**: a Look's form without its colours —
/// the theme whose shape, type, artwork framing, focus, motion and surfaces
/// the app wears, plus the Look's layouts (details page, launch ident, TV and
/// desktop chrome). Picking one never touches the palette.
@immutable
class LookStructure {
  final String id;
  final String label;
  final String blurb;

  /// The theme whose FORM this is (`app_structure`).
  final String themeId;

  /// Layout keys the Look sets, minus every colour key.
  final Map<String, String> layout;

  const LookStructure({
    required this.id,
    required this.label,
    required this.blurb,
    required this.themeId,
    required this.layout,
  });

  AppLook get asLook => AppLook(
    id: 'structure:$id',
    label: label,
    blurb: blurb,
    values: {'app_structure': themeId, ...layout},
  );

  bool get isActive => asLook.isActiveIgnoringMirror;
}

/// Appearance → Looks → **Colour palette**: a theme's colours alone (plus the
/// text brightness a curated palette was tuned for). Picking one never
/// touches the structure.
@immutable
class LookPalette {
  final String id;
  final String label;

  /// The theme whose COLOURS these are (`app_theme`).
  final String themeId;

  /// Curated palettes carry the ink level they were tuned for.
  final String? textBrightness;

  const LookPalette({
    required this.id,
    required this.label,
    required this.themeId,
    this.textBrightness,
  });

  bool get isActive =>
      StorageService.appThemeCached == themeId &&
      (textBrightness == null ||
          TextBrightnessController.current.name == textBrightness);
}

abstract final class LookParts {
  static const Map<String, String> _structureBlurbs = {
    'classic': 'The original form: soft cards, the classic details page and '
        'Canvas TV home.',
    'spotlight': 'Full-bleed art, borderless focus that lifts and tilts, the '
        'Showcase details page and pill navigation.',
    'midnight': 'Glass panes and a focus ring, the Stage details page, Horizon '
        'ident and Stage Discover.',
    'console': 'Squared corners and monospaced type, the Console details page '
        'and Blueprint ident.',
    'cinema': 'Widescreen and unhurried — grain, deep margins, the Marquee '
        'details page and Anamorphic ident.',
    'neon': 'Rounded and bold, the Stage details page and Neon ident.',
    'quiet': 'Restrained and calm, the Dossier details page and Silk ident.',
  };

  /// One structure per shipped Look, in the Looks' order.
  static final List<LookStructure> structures = [
    for (final look in AppLooks.all)
      LookStructure(
        id: look.id,
        label: look.label,
        blurb: _structureBlurbs[look.id] ?? look.blurb,
        themeId: look.values['app_theme'] ?? AppThemes.legacyId,
        layout: {
          for (final e in look.values.entries)
            if (!_paletteKeys.contains(e.key)) e.key: e.value,
        },
      ),
  ];

  /// The curated palettes (one per Look), then every other shipped theme's
  /// colours.
  static final List<LookPalette> curatedPalettes = [
    for (final look in AppLooks.all)
      LookPalette(
        id: look.id,
        label: look.label,
        themeId: look.values['app_theme'] ?? AppThemes.legacyId,
        textBrightness: look.values['text_brightness'],
      ),
  ];

  static List<LookPalette> morePalettes(
    List<({String id, String label})> shippedThemes,
  ) {
    final curated = {for (final p in curatedPalettes) p.themeId};
    return [
      for (final t in shippedThemes)
        if (!curated.contains(t.id))
          LookPalette(id: 'theme:${t.id}', label: t.label, themeId: t.id),
    ];
  }

  static LookStructure? activeStructure() {
    for (final s in structures) {
      if (s.isActive) return s;
    }
    return null;
  }

  /// The palette's name: its Look's when curated, else the theme's own.
  static String paletteLabel(String themeId) {
    for (final p in curatedPalettes) {
      if (p.themeId == themeId) return p.label;
    }
    return themeId == AppThemes.legacyId
        ? 'Debrify Classic'
        : DetailThemes.byId(themeId).label;
  }

  /// "Spotlight · Midnight Signal" — structure, then palette — for the
  /// Settings row that opens Looks.
  static String currentLabel() =>
      '${activeStructure()?.label ?? 'Custom'} · '
      '${paletteLabel(StorageService.appThemeCached)}';

  /// Picks a palette while keeping the structure exactly where it is.
  ///
  /// With no structure picked the app follows the palette's own form, so a
  /// palette change would silently restyle everything else too. Pinning the
  /// current form first is what keeps the two isolated.
  static Future<void> applyPalette(LookPalette palette) async {
    final controller = AppThemeController.instance;
    if (controller.structureId.isEmpty) {
      await controller.selectStructure(controller.effectiveStructureId);
    }
    LookApplier.noteExternalWrite('app_theme');
    await controller.select(palette.themeId);
    final tb = palette.textBrightness;
    if (tb != null) {
      LookApplier.noteExternalWrite('text_brightness');
      await LookKeys.textBrightness.write(tb);
    }
  }

  static Future<void> applyStructure(LookStructure structure) =>
      LookApplier.apply(structure.asLook);
}

/// Applies a Look.
///
/// ## What it guarantees
///
/// * **Publish-first.** Every key's synchronous mirror is updated before any
///   `await`, so the UI is correct on the very next frame whatever happens to
///   the writes. This is the pattern `AppThemeController.select` already
///   proved.
/// * **A human beats a preset.** Each key's generation is snapshotted before
///   the apply; if something else writes that key mid-flight, the applier
///   skips it rather than stamping over a deliberate choice.
/// * **Live, not on restart.** Each key's own change-callback is fired, so a
///   Look lands exactly like a manual pick.
///
/// ## What it does NOT guarantee, stated plainly
///
/// It is **not a transaction**. A crash mid-apply leaves a partial Look — the
/// next apply fixes it, and until then the picker honestly reads *Custom*. A
/// manual change made in the same handful of milliseconds resolves
/// last-writer-wins per key rather than atomically. Both are acceptable for a
/// bundle of cosmetic preferences, and neither is worth the durable
/// preference-transaction machinery that fixing them properly would need.
abstract final class LookApplier {
  static final Map<String, int> _generation = {};

  /// Bumped by [apply] and by [noteExternalWrite] — the hook a manual picker
  /// can call to make itself visible to an in-flight apply.
  static int generationOf(String keyId) => _generation[keyId] ?? 0;

  static void noteExternalWrite(String keyId) =>
      _generation[keyId] = generationOf(keyId) + 1;

  static Future<void> apply(AppLook look) async {
    // Snapshot first: everything below is compared against this, so a write
    // that lands during the apply is detectable.
    final before = <String, int>{
      for (final id in look.values.keys) id: generationOf(id),
    };

    for (final entry in look.values.entries) {
      final key = LookKeys.byId(entry.key);
      if (key == null) continue; // validate() reports these; never throw here
      if (generationOf(entry.key) != before[entry.key]) continue; // human won
      noteExternalWrite(entry.key);
      try {
        await key.write(entry.value);
      } catch (e) {
        // A cosmetic preference must never take the app down with it. The
        // mirror is already published, so the session is correct either way;
        // the cost of a failed write is stickiness across a restart.
        debugPrint('LookApplier: ${entry.key} failed: $e');
      }
      key.notify?.call();
    }
  }

  @visibleForTesting
  static void debugResetGenerations() => _generation.clear();
}
