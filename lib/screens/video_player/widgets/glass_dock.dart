import 'package:flutter/material.dart';

import '../../../theme/app_motion.dart' show kMenuSheetAnimation;
import '../services/playback_ui_clock.dart';
import '../utils/aspect_mode_utils.dart';
import 'controls.dart';
import 'dock_widgets.dart' show DockExtentReporter;
import 'liquid_glass.dart';

export 'liquid_glass.dart' show GlassSurface, GlassVariant;

/// The `glass` dock: minimal frosted-glass controls.
///
/// Three things on screen, nothing else:
///  * a quiet top line — back, a centred title, lock / PiP;
///  * a centred transport — −10 s, play/pause, +10 s — as frosted circles;
///  * one frosted panel at the bottom holding the scrubber and the two or
///    three actions that matter (Episodes, Audio & subtitles, Next). Every
///    other tool lives behind a single More button.
///
/// Palette and size preferences are inert here: the look is white on frost,
/// which reads over any colour grade.
class GlassDock extends StatelessWidget {
  final Controls c;
  const GlassDock({super.key, required this.c});

  static const Color _ink = Color(0xFFFFFFFF);
  static const Color _inkDim = Color(0xB3FFFFFF);
  static const Color _record = Color(0xFFF43F5E);

  static String _fmt(Duration d) {
    final abs = d.abs();
    final h = abs.inHours;
    final m = abs.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = abs.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  bool _compact(BuildContext context) =>
      MediaQuery.sizeOf(context).shortestSide < 500;

  @override
  Widget build(BuildContext context) {
    final compact = _compact(context);
    final bottom = _bottomUnit(context);
    final stack = Stack(
      children: [
        // Soft shades for legibility only — no bands, no boxes.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Container(
              height: 150,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0x8C000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
        ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            child: Container(
              height: 220,
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Color(0x99000000), Color(0x00000000)],
                ),
              ),
            ),
          ),
        ),
        Positioned(top: 0, left: 0, right: 0, child: _topBar(context)),
        if (!c.hideOptions)
          Positioned.fill(child: Center(child: _transport(compact))),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: c.onDockExtent == null
              ? bottom
              : DockExtentReporter(
                  onExtent: c.onDockExtent!,
                  generation: c.geometryGeneration,
                  child: bottom,
                ),
        ),
      ],
    );
    // One shared backdrop read for every glass piece on screen, and the
    // sampled frame brightness for the dynamic ones.
    final grouped = BackdropGroup(child: stack);
    final brightness = c.glassBrightness;
    return brightness == null
        ? grouped
        : GlassBrightnessScope(brightness: brightness, child: grouped);
  }

  // ── Top ────────────────────────────────────────────────────────────────

  ({String headline, String? detail}) get _identity {
    final split = c.title.indexOf(' — ');
    final headline = split < 0 ? c.title : c.title.substring(0, split);
    final episode = split < 0 ? null : c.title.substring(split + 3);
    final detail = [
      if (episode != null && episode.isNotEmpty) episode,
      if (c.subtitle != null && c.subtitle!.isNotEmpty) c.subtitle!,
    ].join('  ·  ');
    return (headline: headline, detail: detail.isEmpty ? null : detail);
  }

  Widget _topBar(BuildContext context) {
    const size = 42.0;
    const gap = 8.0;
    final left = <Widget>[
      if (!c.hideBackButton)
        GlassCircleButton(
          icon: Icons.arrow_back_rounded,
          variant: GlassVariant.translucent,
          tooltip: 'Back',
          size: size,
          onPressed: c.onBack,
        ),
    ];
    final right = <Widget>[
      if (c.onLock != null)
        GlassCircleButton(
          icon: Icons.lock_open_rounded,
          variant: GlassVariant.translucent,
          tooltip: 'Lock screen',
          size: size,
          onPressed: c.onLock!,
        ),
      if (c.showPipButton && c.onPip != null)
        GlassCircleButton(
          icon: Icons.picture_in_picture_alt_rounded,
          variant: GlassVariant.translucent,
          tooltip: 'Picture in picture',
          size: size,
          onPressed: c.onPip!,
        ),
    ];
    final sides = left.length > right.length ? left.length : right.length;
    final sideW = sides == 0 ? 0.0 : sides * size + (sides - 1) * gap + 12;
    final identity = _identity;

    List<Widget> spaced(List<Widget> items) => [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) const SizedBox(width: gap),
        items[i],
      ],
    ];

    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
        child: SizedBox(
          height: size,
          child: Stack(
            children: [
              if (identity.headline.isNotEmpty || identity.detail != null)
                Positioned.fill(
                  left: sideW,
                  right: sideW,
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (identity.headline.isNotEmpty)
                          Text(
                            identity.headline,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: _ink,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.1,
                              height: 1.2,
                              shadows: [
                                Shadow(
                                  color: Color(0x66000000),
                                  blurRadius: 10,
                                ),
                              ],
                            ),
                          ),
                        if (identity.detail != null)
                          Text(
                            identity.detail!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: _inkDim,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                              height: 1.3,
                              shadows: [
                                Shadow(color: Color(0x66000000), blurRadius: 8),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: spaced(left),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: spaced(right),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Centre ─────────────────────────────────────────────────────────────

  Widget _transport(bool compact) {
    final playSize = compact ? 68.0 : 80.0;
    final sideSize = compact ? 50.0 : 58.0;
    final gap = compact ? 36.0 : 56.0;
    final canSkip =
        !c.hideSeekbar && c.onSeekBackward != null && c.onSeekForward != null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (canSkip) ...[
          GlassCircleButton(
            icon: Icons.replay_10_rounded,
            tooltip: 'Back 10 seconds',
            size: sideSize,
            onPressed: c.onSeekBackward!,
          ),
          SizedBox(width: gap),
        ],
        GlassCircleButton(
          icon: c.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          tooltip: c.isPlaying ? 'Pause' : 'Play',
          size: playSize,
          iconScale: 0.5,
          strong: true,
          onPressed: c.onPlayPause,
        ),
        if (canSkip) ...[
          SizedBox(width: gap),
          GlassCircleButton(
            icon: Icons.forward_10_rounded,
            tooltip: 'Forward 10 seconds',
            size: sideSize,
            onPressed: c.onSeekForward!,
          ),
        ],
      ],
    );
  }

  // ── Bottom ─────────────────────────────────────────────────────────────

  Widget _bottomUnit(BuildContext context) {
    final compact = _compact(context);
    final infoPanel = c.infoPanel;
    final hasPanel = !c.hideOptions || !c.hideSeekbar;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(
          compact ? 12 : 24,
          0,
          compact ? 12 : 24,
          compact ? 10 : 18,
        ),
        child: Center(
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (infoPanel != null)
                  c.onInfoPanelExtent == null
                      ? infoPanel
                      : DockExtentReporter(
                          onExtent: c.onInfoPanelExtent!,
                          generation: c.infoPanelGeneration,
                          child: infoPanel,
                        ),
                if (infoPanel != null && hasPanel) const SizedBox(height: 10),
                if (hasPanel)
                  GlassSurface(
                    variant: GlassVariant.dynamic,
                    radius: BorderRadius.circular(
                      compact
                          ? GlassTokens.current.radiusPanelCompact
                          : GlassTokens.current.radiusPanel,
                    ),
                    padding: EdgeInsets.fromLTRB(
                      compact ? 14 : 18,
                      c.hideSeekbar ? 6 : 4,
                      compact ? 8 : 12,
                      c.hideOptions ? 4 : 6,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!c.hideSeekbar) _scrubber(),
                        if (!c.hideOptions) _actionRow(context),
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

  Widget _scrubber() {
    return ValueListenableBuilder<PlaybackUiClockValue>(
      valueListenable: c.clock,
      builder: (context, value, _) {
        final total = value.duration.inMilliseconds <= 0
            ? 1
            : value.duration.inMilliseconds;
        final progress = (value.position.inMilliseconds / total).clamp(
          0.0,
          1.0,
        );
        const timeStyle = TextStyle(
          color: _ink,
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
          fontFeatures: [FontFeature.tabularFigures()],
        );
        return SizedBox(
          height: 36,
          child: Row(
            children: [
              Text(_fmt(value.position), style: timeStyle),
              Expanded(
                child: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    trackHeight: 3,
                    trackShape: const RoundedRectSliderTrackShape(),
                    activeTrackColor: _ink,
                    inactiveTrackColor: const Color(0x40FFFFFF),
                    thumbColor: _ink,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 6,
                      elevation: 0,
                      pressedElevation: 0,
                    ),
                    overlayColor: const Color(0x1FFFFFFF),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 14,
                    ),
                  ),
                  child: Slider(
                    min: 0,
                    max: 1,
                    value: progress,
                    onChangeStart: (_) => c.onSeekBarChangedStart(),
                    onChanged: c.onSeekBarChanged,
                    onChangeEnd: (_) => c.onSeekBarChangeEnd(),
                  ),
                ),
              ),
              Padding(
                // Optically align with the panel's right padding, which is
                // tighter to leave room for the More button.
                padding: const EdgeInsets.only(right: 6),
                child: Text(_fmt(value.duration), style: timeStyle),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Every tool, in priority order. `primary` tools may sit in the panel;
  /// the rest only ever appear under More. Armed state (recording, a sleep
  /// timer) promotes a tool so its state stays visible.
  List<_GlassAction> _actions() {
    final sleepArmed = c.sleepTimerLabel != null;
    return [
      if (c.onLiveEdgeAction != null)
        _GlassAction(
          c.liveEdgeActionActive ? Icons.live_tv_rounded : Icons.replay_rounded,
          c.liveEdgeActionLoading
              ? 'Preparing…'
              : c.liveEdgeActionActive
              ? 'Go live'
              : 'Start over',
          c.liveEdgeActionLoading ? () {} : c.onLiveEdgeAction!,
          primary: true,
          active: c.liveEdgeActionActive,
        ),
      if (c.hasRecord && c.onRecord != null)
        _GlassAction(
          c.isRecording
              ? Icons.stop_circle_rounded
              : Icons.fiber_manual_record_rounded,
          c.isRecording ? 'Stop recording' : 'Record',
          c.onRecord!,
          primary: c.isRecording,
          active: c.isRecording,
          tint: c.isRecording ? _record : null,
        ),
      if (c.hasGuide && c.onShowGuide != null)
        _GlassAction(
          Icons.grid_view_rounded,
          'Guide',
          c.onShowGuide!,
          primary: true,
        ),
      if (c.hasIptvChannels && c.onShowIptvChannels != null)
        _GlassAction(
          Icons.calendar_view_week_rounded,
          'Channels',
          c.onShowIptvChannels!,
          primary: true,
        ),
      if (c.hasPlaylist)
        _GlassAction(
          Icons.video_library_outlined,
          'Episodes',
          c.onShowPlaylist,
          primary: true,
        ),
      _GlassAction(
        Icons.subtitles_outlined,
        'Audio & Subtitles',
        c.onShowTracks,
        primary: true,
      ),
      if (sleepArmed)
        _GlassAction(
          Icons.bedtime_rounded,
          c.sleepTimerLabel!,
          c.onSleepTimer,
          primary: true,
          active: true,
        ),
      if (c.hasNext && c.onNext != null)
        _GlassAction(
          Icons.skip_next_rounded,
          'Next Episode',
          c.onNext!,
          primary: true,
        ),
      if (c.hasNextChannel && c.onNextChannel != null)
        _GlassAction(
          Icons.tv_rounded,
          'Next Channel',
          c.onNextChannel!,
          primary: true,
        ),
      // ── More only ──
      if (c.hasPrevious && c.onPrevious != null)
        _GlassAction(
          Icons.skip_previous_rounded,
          'Previous Episode',
          c.onPrevious!,
        ),
      if (c.liveEdgeActionActive && c.onToggleStartOverTimeline != null)
        _GlassAction(
          Icons.timeline_rounded,
          c.startOverTimelineVisible ? 'Hide timeline' : 'Seek',
          c.onToggleStartOverTimeline!,
          active: c.startOverTimelineVisible,
        ),
      if (c.hasStremioSources && c.onShowStremioSources != null)
        _GlassAction(
          Icons.swap_horiz_rounded,
          'Sources',
          c.onShowStremioSources!,
        ),
      if (!c.hideSpeed)
        _GlassAction(
          Icons.speed_rounded,
          'Playback speed',
          c.onSpeed,
          value: '${c.speed}x',
        ),
      if (!sleepArmed)
        _GlassAction(Icons.bedtime_outlined, 'Sleep timer', c.onSleepTimer),
      _GlassAction(
        Icons.aspect_ratio_rounded,
        'Aspect ratio',
        c.onAspect,
        value: AspectModeUtils.aspectModeToString(c.aspectMode),
      ),
      if (!c.hideRandom)
        _GlassAction(
          Icons.shuffle_rounded,
          'Play something random',
          c.onRandom,
        ),
      if (c.showRotate)
        _GlassAction(
          Icons.screen_rotation_rounded,
          c.isLandscape ? 'Lock to portrait' : 'Lock to landscape',
          c.onRotate,
        ),
    ];
  }

  Widget _actionRow(BuildContext context) {
    final actions = _actions();
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context);
        // Measure in the font the labels actually render in.
        final labelStyle = DefaultTextStyle.of(context).style.merge(
          const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        );
        final showLabels = constraints.maxWidth >= 520;

        // Trailing cluster: volume (desktop), fullscreen, More.
        final showVolume =
            c.onVolumeChanged != null && constraints.maxWidth >= 640;
        final trailing = <Widget>[
          if (showVolume) _volume(context),
          if (c.showFullscreen && c.onFullscreen != null)
            GlassGhostButton(
              icon: Icons.fullscreen_rounded,
              tooltip: 'Fullscreen',
              onPressed: c.onFullscreen!,
            ),
        ];
        final trailingW =
            (showVolume ? 140.0 : 0.0) +
            (c.showFullscreen && c.onFullscreen != null ? 44.0 : 0.0) +
            44.0; // More

        double widthOf(_GlassAction a) {
          if (!showLabels) return 44;
          final painter = TextPainter(
            text: TextSpan(text: a.label, style: labelStyle),
            textDirection: TextDirection.ltr,
            textScaler: textScale,
            maxLines: 1,
          )..layout();
          final w = painter.width + 20 + 8 + 24; // icon, gap, padding
          painter.dispose();
          return w;
        }

        final budget = constraints.maxWidth - trailingW;
        final shown = <_GlassAction>[];
        var used = 0.0;
        for (final a in actions.where((a) => a.primary)) {
          final w = widthOf(a);
          if (used + w > budget) break;
          shown.add(a);
          used += w;
        }
        final overflow = actions.where((a) => !shown.contains(a)).toList();

        return SizedBox(
          height: 44,
          child: Row(
            children: [
              for (final a in shown)
                GlassGhostButton(
                  icon: a.icon,
                  label: showLabels ? a.label : null,
                  tooltip: a.value == null
                      ? a.label
                      : '${a.label} · ${a.value}',
                  tint: a.tint,
                  active: a.active,
                  onPressed: a.onPressed,
                ),
              const Spacer(),
              ...trailing,
              if (overflow.isNotEmpty)
                GlassGhostButton(
                  icon: Icons.more_horiz_rounded,
                  tooltip: 'More',
                  onPressed: () => _GlassMoreSheet.show(context, overflow),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _volume(BuildContext context) {
    final v = c.volume;
    return SizedBox(
      width: 140,
      child: Row(
        children: [
          Icon(
            v <= 0.01
                ? Icons.volume_off_rounded
                : v < 0.5
                ? Icons.volume_down_rounded
                : Icons.volume_up_rounded,
            size: 20,
            color: _ink,
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                trackShape: const RoundedRectSliderTrackShape(),
                activeTrackColor: _ink,
                inactiveTrackColor: const Color(0x40FFFFFF),
                thumbColor: _ink,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 5,
                  elevation: 0,
                  pressedElevation: 0,
                ),
                overlayColor: const Color(0x1FFFFFFF),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
              ),
              child: Slider(
                min: 0,
                max: 1,
                value: v.clamp(0.0, 1.0),
                onChanged: c.onVolumeChanged,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Pieces ────────────────────────────────────────────────────────────────

class _GlassAction {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final String? value;
  final bool primary;
  final bool active;
  final Color? tint;
  const _GlassAction(
    this.icon,
    this.label,
    this.onPressed, {
    this.value,
    this.primary = false,
    this.active = false,
    this.tint,
  });
}

/// A round frosted button — the transport and the top-bar corners.
class GlassCircleButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final double size;
  final double iconScale;
  final bool strong;
  final GlassVariant variant;
  final VoidCallback onPressed;

  const GlassCircleButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 44,
    this.iconScale = 0.48,
    this.strong = false,
    this.variant = GlassVariant.dynamic,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        child: SizedBox.square(
          dimension: size,
          child: GlassSurface(
            radius: BorderRadius.circular(size / 2),
            strong: strong,
            variant: variant,
            shadowScale: size / 160,
            child: Material(
              type: MaterialType.transparency,
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onPressed,
                splashColor: const Color(0x26FFFFFF),
                highlightColor: const Color(0x14FFFFFF),
                hoverColor: const Color(0x14FFFFFF),
                child: Center(
                  child: Icon(
                    icon,
                    size: size * iconScale,
                    color: GlassDock._ink,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A borderless icon (+ optional label) button that sits on a glass panel.
class GlassGhostButton extends StatelessWidget {
  final IconData icon;
  final String? label;
  final String tooltip;
  final Color? tint;
  final bool active;
  final VoidCallback onPressed;

  const GlassGhostButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.label,
    this.tint,
    this.active = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = tint ?? GlassDock._ink;
    final content = label == null
        ? SizedBox.square(
            dimension: 44,
            child: Center(child: Icon(icon, size: 21, color: color)),
          )
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 20, color: color),
                const SizedBox(width: 8),
                Text(
                  label!,
                  maxLines: 1,
                  style: TextStyle(
                    color: active ? color : const Color(0xE6FFFFFF),
                    fontSize: 13,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          );
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 600),
      child: Semantics(
        button: true,
        label: tooltip,
        excludeSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onPressed,
            borderRadius: BorderRadius.circular(12),
            splashColor: const Color(0x1FFFFFFF),
            highlightColor: const Color(0x14FFFFFF),
            hoverColor: const Color(0x14FFFFFF),
            child: SizedBox(height: 44, child: content),
          ),
        ),
      ),
    );
  }
}

/// Everything that is not in the panel, as a frosted list.
class _GlassMoreSheet extends StatelessWidget {
  final List<_GlassAction> actions;
  const _GlassMoreSheet(this.actions);

  static Future<void> show(BuildContext context, List<_GlassAction> actions) {
    final size = MediaQuery.sizeOf(context);
    return showModalBottomSheet<void>(
      context: context,
      sheetAnimationStyle: kMenuSheetAnimation,
      backgroundColor: Colors.transparent,
      barrierColor: const Color(0x59000000),
      elevation: 0,
      isScrollControlled: true,
      constraints: BoxConstraints(maxWidth: 440, maxHeight: size.height * 0.9),
      builder: (_) => _GlassMoreSheet(actions),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: GlassSurface(
          variant: GlassVariant.frosted,
          radius: BorderRadius.circular(GlassTokens.current.radiusSheet),
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Material(
            type: MaterialType.transparency,
            child: ListView(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              children: [for (final a in actions) _row(context, a)],
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, _GlassAction a) {
    final color = a.tint ?? GlassDock._ink;
    return Semantics(
      button: true,
      label: a.label,
      child: InkWell(
        onTap: () {
          Navigator.of(context).pop();
          a.onPressed();
        },
        splashColor: const Color(0x1FFFFFFF),
        highlightColor: const Color(0x14FFFFFF),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            child: Row(
              children: [
                Icon(a.icon, size: 20, color: color),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    a.label,
                    style: TextStyle(
                      color: color,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                if (a.value != null)
                  Text(
                    a.value!,
                    style: const TextStyle(
                      color: GlassDock._inkDim,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      fontFeatures: [FontFeature.tabularFigures()],
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
