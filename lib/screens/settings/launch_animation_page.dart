import '../../theme/app_looks.dart';
import 'imported_launch_animations.dart';
import '../../services/launch_animation/launch_animation_library.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import '../../services/storage_service.dart';
import '../../utils/platform_util.dart';
import '../../widgets/launch/launch_ident.dart';
import 'widgets/settings_widgets.dart';
import '../../theme/app_theme_scope.dart';

/// Launch ident picker (`launch_animation`).
///
/// The preview at the top plays the selected ident's REAL painter — the same
/// CustomPainter the splash runs, on the same TV/phone quality path this
/// device would use — looping with a short hold, so what you pick is exactly
/// what you get on the next launch.
class LaunchAnimationPage extends StatefulWidget {
  const LaunchAnimationPage({super.key});

  @override
  State<LaunchAnimationPage> createState() => _LaunchAnimationPageState();
}

class _LaunchAnimationPageState extends State<LaunchAnimationPage> {
  // Sync-cached (warmed in main), so no loading state.
  LaunchIdent _choice = launchIdentFor(StorageService.launchAnimationCached);
  String _palette = StorageService.launchIdentPaletteCached;
  int _selectionGeneration = 0;
  Future<void> _selectionWrites = Future<void>.value();
  late final PageController _mobilePager = PageController(
    initialPage: kLaunchIdents.indexWhere((ident) => ident.id == _choice.id),
    viewportFraction: 0.92,
  );

  /// Non-focusable marker around the options card; used on TV to hand entry
  /// focus to its first focusable descendant (the first option row).
  final FocusNode _firstCardMarker = FocusNode(
    debugLabel: 'launch-anim-first-card',
    skipTraversal: true,
    canRequestFocus: false,
  );

  @override
  void initState() {
    super.initState();
    if (PlatformUtil.isAndroidTvCached) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        // Don't yank focus if it already landed on a real node (only the
        // route's FocusScope holds focus while nothing is focused yet).
        final primary = FocusManager.instance.primaryFocus;
        if (primary != null && primary is! FocusScopeNode) return;
        _firstCardMarker.traversalDescendants.firstOrNull?.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _mobilePager.dispose();
    _firstCardMarker.dispose();
    super.dispose();
  }

  Future<void> _select(LaunchIdent choice) async {
    if (choice.id == StorageService.launchAnimationCached &&
        StorageService.importedLaunchAnimationCached == null) {
      return;
    }
    final generation = ++_selectionGeneration;
    setState(() => _choice = choice);
    // Tell an in-flight Look apply that a human just chose this key, so it
    // does not stamp over the choice. See theme/app_looks.dart.
    LookApplier.noteExternalWrite('launch_animation');
    try {
      await (_selectionWrites = _selectionWrites.then((_) async {
        if (generation != _selectionGeneration) return;
        await StorageService.setLaunchAnimation(choice.id);
      }));
    } catch (error) {
      if (mounted && generation == _selectionGeneration) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('$error')));
      }
    }
    if (mounted && generation == _selectionGeneration) {
      setState(
        () => _choice = launchIdentFor(StorageService.launchAnimationCached),
      );
    }
  }

  Future<void> _selectPalette(String value) async {
    if (value == _palette) return;
    setState(() => _palette = value);
    // Every non-Classic Look writes this key, so without the announcement an
    // in-flight apply would stamp over a choice made here. Same reason every
    // other Appearance picker announces itself.
    LookApplier.noteExternalWrite('launch_ident_palette');
    await StorageService.setLaunchIdentPalette(value);
  }

  @override
  Widget build(BuildContext context) {
    return SettingsPageScaffold(
      title: 'Launch Animation',
      // The split exists for DPAD: in one column the list scrolls the preview
      // off the top exactly when you start walking the options, so you choose
      // an ident you can no longer see. Pinning the preview beside the list
      // keeps the thing being chosen on screen for the whole walk.
      //
      // TV takes it unconditionally — that is the surface with the problem,
      // and a 720p box reports only ~640 logical px, which no sane width
      // threshold would catch. Everywhere else it needs room to be worth it:
      // decisively landscape and wide enough for two usable panes, which
      // covers desktop and tablet windows and leaves phones stacked.
      body: LayoutBuilder(
        builder: (context, constraints) {
          final twoPane =
              PlatformUtil.isAndroidTvCached ||
              (constraints.maxWidth >= 820 &&
                  constraints.maxWidth > constraints.maxHeight * 1.2);
          return twoPane ? _buildTwoPane() : _buildSwipeFeed(constraints);
        },
      ),
    );
  }

  Widget _buildSwipeFeed(BoxConstraints constraints) {
    final applied =
        StorageService.importedLaunchAnimationCached == null &&
        StorageService.launchAnimationCached == _choice.id;
    final previewHeight = (constraints.maxHeight * 0.48)
        .clamp(300.0, 430.0)
        .toDouble();
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: _header(),
          ),
          const SizedBox(height: 18),
          SizedBox(
            height: previewHeight,
            child: PageView.builder(
              controller: _mobilePager,
              itemCount: kLaunchIdents.length,
              onPageChanged: (index) =>
                  setState(() => _choice = kLaunchIdents[index]),
              itemBuilder: (context, index) {
                final ident = kLaunchIdents[index];
                final selected = ident.id == _choice.id;
                return AnimatedPadding(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  padding: EdgeInsets.fromLTRB(
                    6,
                    selected ? 0 : 12,
                    6,
                    selected ? 0 : 12,
                  ),
                  child: TickerMode(
                    enabled: selected,
                    child: _LaunchPreview(
                      key: ValueKey('mobile-preview-${ident.id}'),
                      ident: ident,
                      palette: _palette,
                    ),
                  ),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _choice.label,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                      ),
                    ),
                    Text(
                      '${kLaunchIdents.indexWhere((i) => i.id == _choice.id) + 1} / ${kLaunchIdents.length}',
                      style: TextStyle(
                        color: AppThemeScope.of(context).settings.dim,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(_choice.subtitle),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: applied ? null : () => _select(_choice),
                    icon: Icon(
                      applied
                          ? Icons.check_rounded
                          : Icons.rocket_launch_rounded,
                    ),
                    label: Text(
                      applied ? 'Current animation' : 'Use this animation',
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    'Swipe to preview another animation',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: AppThemeScope.of(context).settings.dim,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              children: [
                _paletteCard(),
                const SizedBox(height: 14),
                _imports(),
                const SizedBox(height: 14),
                _footnote(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTwoPane() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The only focusable pane. Scrolls on its own, so a longer ident
          // list never moves the preview.
          Expanded(
            flex: 5,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(),
                  const SizedBox(height: 18),
                  _paletteCard(),
                  const SizedBox(height: 14),
                  _optionsCard(),
                  _imports(),
                  const SizedBox(height: 14),
                  _footnote(),
                ],
              ),
            ),
          ),
          const SizedBox(width: 24),
          // Pinned preview. Nothing here can take focus, so LEFT/RIGHT keep
          // the DPAD inside the list instead of stranding it on a picture.
          Expanded(flex: 6, child: Center(child: _preview())),
        ],
      ),
    );
  }

  Widget _imports() => ImportedLaunchAnimations(
    onSelectionChanged: () {
      if (mounted) {
        setState(
          () => _choice = launchIdentFor(StorageService.launchAnimationCached),
        );
      }
    },
  );

  Widget _preview() {
    final id = StorageService.importedLaunchAnimationCached;
    return id == null
        ? _LaunchPreview(ident: _choice, palette: _palette)
        : AspectRatio(
            aspectRatio: 16 / 9,
            child: ImportedAnimationPreview(
              key: ValueKey(
                '$id:${LaunchAnimationLibrary.instance.revision.value}',
              ),
              id: id,
            ),
          );
  }

  Widget _header() => const SettingsPageHeader(
    icon: Icons.rocket_launch_rounded,
    title: 'Launch Animation',
    subtitle: 'The ident Nextup plays while it starts',
  );

  /// Whether the ident wears its own colours or the app theme's.
  ///
  /// Placed ABOVE the ident list rather than inside it: it is a different
  /// question from "which ident", and burying it as an eighteenth radio row
  /// would read as another ident.
  Widget _paletteCard() {
    final app = AppThemeScope.of(context);
    final themed = _palette == 'theme';
    return SettingsSection(
      title: 'Built-in animation colour',
      children: [
        SettingsToggleTile(
          icon: Icons.palette_outlined,
          title: 'Match the app theme',
          subtitle: app.isLegacy
              // Honest about doing nothing: legacy IS the ident's own world.
              ? 'Pick an App Theme first — Nextup Classic leaves every ident '
                    'in its own colours'
              : 'The ident\'s room takes ${app.label}\'s colours. Its '
                    'motion, mark and composition are unchanged, and an ident '
                    'that would become unreadable keeps its own.',
          value: themed,
          onChanged: (v) => _selectPalette(v ? 'theme' : 'ident'),
        ),
      ],
    );
  }

  Widget _optionsCard() => Focus(
    focusNode: _firstCardMarker,
    canRequestFocus: false,
    skipTraversal: true,
    child: SettingsSection(
      title: '',
      children: [for (final ident in kLaunchIdents) _optionRow(ident)],
    ),
  );

  Widget _footnote() => Text(
    'The preview runs the real splash painter on this device\'s quality '
    'path. Your pick plays on the next launch.',
    style: TextStyle(
      fontSize: 12.5,
      height: 1.45,
      color: AppThemeScope.of(context).settings.dim,
    ),
  );

  /// Radio-style row — a plain [SettingsTile] (the DPAD-proven row) with a
  /// check on the active one.
  Widget _optionRow(LaunchIdent ident) {
    final t = AppThemeScope.of(context).settings;
    final bool active =
        StorageService.importedLaunchAnimationCached == null &&
        _choice.id == ident.id;
    return SettingsTile(
      icon: active
          ? Icons.radio_button_checked_rounded
          : Icons.radio_button_unchecked_rounded,
      title: ident.label,
      subtitle: ident.subtitle,
      trailing: active
          ? Icon(Icons.check_rounded, size: 20, color: t.accent2)
          : const SizedBox.shrink(),
      onTap: () => _select(ident),
    );
  }
}

/// Loops the selected ident's real painter: play → hold 1.4 s → replay.
class _LaunchPreview extends StatefulWidget {
  final LaunchIdent ident;

  /// 'ident' or 'theme' — the same pref the splash reads. Passed as the raw
  /// string so the preview re-derives the palette from the LIVE theme, which
  /// is what makes toggling the switch show its effect immediately.
  final String palette;

  const _LaunchPreview({super.key, required this.ident, required this.palette});

  @override
  State<_LaunchPreview> createState() => _LaunchPreviewState();
}

class _LaunchPreviewState extends State<_LaunchPreview>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  CustomPainter? _painter;
  Timer? _holdTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: widget.ident.revealDuration,
      vsync: this,
    )..addStatusListener(_handleStatus);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _restart();
  }

  @override
  void didUpdateWidget(covariant _LaunchPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ident.id != widget.ident.id ||
        oldWidget.palette != widget.palette) {
      _restart();
    }
  }

  /// The palette this preview is painting — the ident's own, or the live app
  /// theme's. Recomputed on every restart so the switch shows its effect at
  /// once rather than on the next launch.
  IdentPalette get _resolved => widget.palette == 'theme'
      ? IdentPalette.fromTheme(widget.ident, AppThemeScope.of(context))
      : widget.ident.palette;

  /// Null unless themed — see the note in `app_initializer.dart`. An ident's
  /// own palette carries its SWEEP colours, which are not what its painter
  /// draws the mark with.
  IdentPalette? get _painterPalette =>
      widget.palette == 'theme' ? _resolved : null;

  void _handleStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    _holdTimer?.cancel();
    _holdTimer = Timer(const Duration(milliseconds: 1400), () {
      if (mounted) _controller.forward(from: 0);
    });
  }

  void _restart() {
    _holdTimer?.cancel();
    _controller
      ..stop()
      ..duration = widget.ident.revealDuration;
    _painter = widget.ident.createPainter(
      _controller,
      isTelevision: () => PlatformUtil.isAndroidTvCached,
      palette: _painterPalette,
    );
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _controller
      ..removeStatusListener(_handleStatus)
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: DecoratedBox(
          // The ident's static backdrop, exactly as the splash composes it —
          // the painter draws only the moving elements over it.
          decoration: _resolved.backdrop,
          child: RepaintBoundary(
            child: CustomPaint(
              painter: _painter,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    );
  }
}
