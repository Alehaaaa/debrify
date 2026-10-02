/// Appearance preferences that stay local to each installation during
/// automatic WebDAV sync (including bootstrap and replay).
///
/// Themes, Looks, palettes, layouts and every other style choice sync like
/// ordinary settings, so a profile looks the same on every device. Only
/// one-time migration checkpoints and per-screen display tuning stay here.
/// These keys are still portable through explicit backups and
/// profile-default copies.
abstract final class ProfileAppearancePreferences {
  static const Set<String> keys = <String>{
    // One-time checkpoints belong to the installation that ran them.
    'defaults_generation',
    'sources_presentation_defaults_copied_v1',
    'subtitle_extreme_bottom_default_adopted_v1',
    // Device-local launch package; never portable.
    'imported_launch_animation_v1',
    // Display/performance tuning for this particular screen and GPU.
    'tv_ui_scale_percent',
    'tv_low_res_render',
    'tv_hero_artwork_quality',
  };
}
