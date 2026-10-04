/// The `two_tier` dock — everything `classic` is not.
///
/// Lives in its own file so `Controls.build` can branch to it in one
/// expression and leave the legacy tree untouched. That is the whole
/// compatibility strategy: `classic` cannot enter this code, so it cannot
/// regress.
///
/// Three arrangements, chosen from the viewport (never persisted):
/// `narrow` is a single row, `regular` is two tiers, `wide` is zoned.
///
/// See `dev/design/plans/PLAYER_DOCK_STYLES_PLAN.md` §3.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:flutter/foundation.dart' show ValueListenable;

import '../models/gesture_state.dart';
import '../services/playback_ui_clock.dart';
import '../utils/aspect_mode_utils.dart';
import 'dock_style.dart';
import 'dock_widgets.dart';

/// One control the dock can offer, with its availability already resolved.
class _Tool {
  final IconData icon;
  final String label;
  final String? value;
  final bool active;

  /// Overrides the palette accent for semantic state — today only the record
  /// red, which must look the same in every palette.
  final Color? tint;
  final VoidCallback onPressed;
  const _Tool(
    this.icon,
    this.label,
    this.onPressed, {
    this.value,
    this.active = false,
    this.tint,
  });
}

class StyledDock extends StatelessWidget {
  final DockMetrics metrics;
  final DockPalette palette;
  final DockArrangement arrangement;

  final String title;
  final String? subtitle;
  final Widget? infoPanel;

  /// The dock takes the clock rather than a position/duration pair, matching
  /// the legacy path — only the scrub row rebuilds on a tick, not the whole
  /// dock.
  final ValueListenable<PlaybackUiClockValue> clock;
  final bool isPlaying;

  final VoidCallback onPlayPause;
  final VoidCallback onBack;
  final VoidCallback onAspect;
  final VoidCallback onSpeed;
  final VoidCallback onSleepTimer;
  final VoidCallback onShowTracks;
  final VoidCallback onShowPlaylist;
  final VoidCallback onRandom;
  final VoidCallback onRotate;
  final VoidCallback onSeekBarChangedStart;
  final ValueChanged<double> onSeekBarChanged;
  final VoidCallback onSeekBarChangeEnd;

  final VoidCallback? onNext;
  final VoidCallback? onPrevious;
  final VoidCallback? onNextChannel;
  final VoidCallback? onShowGuide;
  final VoidCallback? onShowIptvChannels;
  final VoidCallback? onShowStremioSources;
  final VoidCallback? onRecord;
  final VoidCallback? onLiveEdgeAction;
  final bool liveEdgeActionActive;
  final bool liveEdgeActionLoading;
  final VoidCallback? onToggleStartOverTimeline;
  final bool startOverTimelineVisible;
  final VoidCallback? onPip;

  /// Locks the screen against touches (phones and tablets); null hides it.
  final VoidCallback? onLock;

  final bool hasNext;
  final bool hasPrevious;
  final bool hasNextChannel;
  final bool hasGuide;
  final bool hasIptvChannels;
  final bool hasStremioSources;
  final bool hasPlaylist;
  final bool hasRecord;
  final bool isRecording;
  final bool showPipButton;

  final bool hideSeekbar;
  final bool hideOptions;
  final bool hideBackButton;
  final bool hideSpeed;
  final bool hideRandom;

  /// Supplied by the host rather than read from `PlatformUtil` here, so a
  /// desktop test host can still exercise the control.
  final bool showRotate;
  final bool isLandscape;

  final String? sleepTimerLabel;
  final double speed;
  final AspectMode aspectMode;

  /// Reports the BOTTOM UNIT's height — not this widget's, whose root is a
  /// full-screen Stack. Measuring the Stack would report the viewport and
  /// protect the entire screen from gestures.
  final void Function(double, int)? onDockExtent;

  /// The host's geometry generation, handed to both reporters.
  /// 0..1. The wide dock anchors its play button with a volume control, the
  /// way the design does; without it the transport floats alone.
  final double volume;
  final ValueChanged<double>? onVolumeChanged;

  /// Only Windows/Linux drive fullscreen through windowManager; elsewhere the
  /// OS owns it, so the control would be a lie.
  final bool showFullscreen;
  final VoidCallback? onFullscreen;

  final int geometryGeneration;

  /// Separate from [geometryGeneration]: the panel's structure can change
  /// without the dock's geometry inputs changing, and vice versa.
  final int infoPanelGeneration;

  /// Reports the info panel's measured height — the second pass of the
  /// two-pass contract. Until it fires the budget reserves the bound.
  final void Function(double, int)? onInfoPanelExtent;

  const StyledDock({
    super.key,
    required this.metrics,
    required this.palette,
    required this.arrangement,
    required this.title,
    required this.subtitle,
    required this.infoPanel,
    required this.clock,
    required this.isPlaying,
    required this.onPlayPause,
    required this.onBack,
    required this.onAspect,
    required this.onSpeed,
    required this.onSleepTimer,
    required this.onShowTracks,
    required this.onShowPlaylist,
    required this.onRandom,
    required this.onRotate,
    required this.onSeekBarChangedStart,
    required this.onSeekBarChanged,
    required this.onSeekBarChangeEnd,
    required this.speed,
    required this.aspectMode,
    required this.isLandscape,
    required this.hideSeekbar,
    required this.hideOptions,
    required this.hideBackButton,
    this.onNext,
    this.onPrevious,
    this.onNextChannel,
    this.onShowGuide,
    this.onShowIptvChannels,
    this.onShowStremioSources,
    this.onRecord,
    this.onLiveEdgeAction,
    this.liveEdgeActionActive = false,
    this.liveEdgeActionLoading = false,
    this.onToggleStartOverTimeline,
    this.startOverTimelineVisible = false,
    this.onPip,
    this.onLock,
    this.hasNext = false,
    this.hasPrevious = false,
    this.hasNextChannel = false,
    this.hasGuide = false,
    this.hasIptvChannels = false,
    this.hasStremioSources = false,
    this.hasPlaylist = false,
    this.hasRecord = false,
    this.isRecording = false,
    this.showPipButton = false,
    this.hideSpeed = false,
    this.hideRandom = false,
    this.showRotate = true,
    this.sleepTimerLabel,
    this.onDockExtent,
    this.onInfoPanelExtent,
    this.volume = 1.0,
    this.onVolumeChanged,
    this.showFullscreen = false,
    this.onFullscreen,
    this.geometryGeneration = 0,
    this.infoPanelGeneration = 0,
  });

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// The canonical label — the same helper the legacy dock uses, so the two
  /// styles never disagree about what a mode is called.
  String get _aspectLabel => AspectModeUtils.aspectModeToString(aspectMode);

  /// Every available tool, in **availability-priority order**.
  ///
  /// `Controls` has no live/VOD input and the guards are independent — live
  /// IPTV can have Channels without Guide, playlist VOD usually has Episodes
  /// without Sources. A mode-based mapping collapsed to two buttons in all
  /// those cases; this cannot, because the tail (Subtitles, Aspect, Sleep) is
  /// unconditional, so three are always found.
  ///
  /// Record and Guide lead because they are the most session-specific and the
  /// least reachable elsewhere.
  List<_Tool> _tools() {
    return [
      if (onLiveEdgeAction != null)
        _Tool(
          liveEdgeActionActive ? Icons.live_tv_rounded : Icons.replay_rounded,
          liveEdgeActionLoading
              ? 'Preparing start over…'
              : liveEdgeActionActive
              ? 'Go live'
              : 'Start from beginning',
          liveEdgeActionLoading ? () {} : onLiveEdgeAction!,
          active: liveEdgeActionActive,
        ),
      if (liveEdgeActionActive && onToggleStartOverTimeline != null)
        _Tool(
          Icons.timeline_rounded,
          startOverTimelineVisible ? 'Hide timeline' : 'Seek',
          onToggleStartOverTimeline!,
          active: startOverTimelineVisible,
        ),
      if (hasRecord && onRecord != null)
        _Tool(
          isRecording
              ? Icons.stop_circle_rounded
              : Icons.fiber_manual_record_rounded,
          isRecording ? 'Stop recording' : 'Record',
          onRecord!,
          active: isRecording,
          // Semantic, never the palette accent.
          tint: isRecording ? DockPalette.record : null,
        ),
      if (hasGuide && onShowGuide != null)
        _Tool(Icons.grid_view_rounded, 'Guide', onShowGuide!),
      // Renamed from "Guide": the legacy dock rendered that word twice, side
      // by side, for two different destinations.
      if (hasIptvChannels && onShowIptvChannels != null)
        _Tool(
          Icons.calendar_view_week_rounded,
          'Channels',
          onShowIptvChannels!,
        ),
      if (hasNextChannel && onNextChannel != null)
        _Tool(Icons.tv_rounded, 'Next channel', onNextChannel!),
      if (hasPlaylist)
        _Tool(Icons.playlist_play_rounded, 'Episodes', onShowPlaylist),
      if (hasStremioSources && onShowStremioSources != null)
        _Tool(Icons.swap_horiz_rounded, 'Sources', onShowStremioSources!),
      _Tool(Icons.subtitles_rounded, 'Subtitles & audio', onShowTracks),
      _Tool(
        Icons.aspect_ratio_rounded,
        'Aspect ratio',
        onAspect,
        value: _aspectLabel,
      ),
      _Tool(
        sleepTimerLabel == null
            ? Icons.bedtime_outlined
            : Icons.bedtime_rounded,
        'Sleep timer',
        onSleepTimer,
        value: sleepTimerLabel,
        active: sleepTimerLabel != null,
      ),
      if (!hideSpeed)
        _Tool(
          Icons.speed_rounded,
          'Playback speed',
          onSpeed,
          value: '${speed}x',
        ),
      if (!hideRandom)
        _Tool(Icons.shuffle_rounded, 'Play something random', onRandom),
      // Meaningless on desktop, where the window does not rotate. Classic
      // still shows it unconditionally.
      if (showRotate)
        _Tool(
          Icons.screen_rotation_rounded,
          isLandscape ? 'Lock to portrait' : 'Lock to landscape',
          onRotate,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final tools = _tools();
    return Stack(
      children: [
        // Identity always lives up top, with room to breathe; the bottom
        // glass is only for controls.
        Positioned(top: 0, left: 0, right: 0, child: _topBar(context)),
        // Transport in the middle of the picture, like the players people
        // know; only its buttons take touches, the rest passes through.
        if (!hideOptions)
          Positioned.fill(
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: _transport(),
              ),
            ),
          ),
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: onDockExtent == null
              ? _bottomUnit(context, tools)
              : DockExtentReporter(
                  onExtent: onDockExtent!,
                  generation: geometryGeneration,
                  child: _bottomUnit(context, tools),
                ),
        ),
      ],
    );
  }

  /// The title line and the line under it. A "Show — Episode" title splits
  /// so the show reads as the headline and the episode joins the detail
  /// line ("Episode name · Season 2, Episode 4").
  ({String headline, String? detail}) get _identity {
    final split = title.indexOf(' — ');
    final headline = split < 0 ? title : title.substring(0, split);
    final episode = split < 0 ? null : title.substring(split + 3);
    final detail = [
      if (episode != null && episode.isNotEmpty) episode,
      if (subtitle != null && subtitle!.isNotEmpty) subtitle!,
    ].join('  ·  ');
    return (headline: headline, detail: detail.isEmpty ? null : detail);
  }

  Widget _topBar(BuildContext context) {
    final identity = _identity;
    return Container(
      padding: EdgeInsets.fromLTRB(
        metrics.padX * 1.8,
        metrics.padY * 1.6,
        metrics.padX * 1.8,
        metrics.padY * 4,
      ),
      // A soft shade, not a band: enough for white type over bright frames.
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xB3000000), Color(0x00000000)],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!hideBackButton) ...[
              DockGlassIconButton(
                icon: Icons.arrow_back_rounded,
                tooltip: 'Back',
                onPressed: onBack,
                metrics: metrics,
                palette: palette,
              ),
              SizedBox(width: metrics.gap * 1.5),
            ],
            Expanded(
              child: Padding(
                // Optically centre a one-line title on the round buttons.
                padding: EdgeInsets.only(top: metrics.padY * 0.4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (identity.headline.isNotEmpty)
                      Text(
                        identity.headline,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.ink,
                          fontSize: metrics.label * 1.7,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.4,
                          height: 1.15,
                          shadows: const [
                            Shadow(color: Color(0x66000000), blurRadius: 12),
                          ],
                        ),
                      ),
                    if (identity.detail != null) ...[
                      SizedBox(height: metrics.gap * 0.5),
                      Text(
                        identity.detail!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: palette.inkDim,
                          fontSize: metrics.label * 1.05,
                          fontWeight: FontWeight.w500,
                          height: 1.3,
                          shadows: const [
                            Shadow(color: Color(0x66000000), blurRadius: 10),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            // Lock and PiP live here, not in the tools row: always in sight,
            // and independent of `hideOptions` and the overflow menu.
            if (onLock != null) ...[
              SizedBox(width: metrics.gap * 1.5),
              DockGlassIconButton(
                icon: Icons.lock_open_rounded,
                tooltip: 'Lock screen',
                onPressed: onLock!,
                metrics: metrics,
                palette: palette,
              ),
            ],
            if (showPipButton && onPip != null) ...[
              SizedBox(width: metrics.gap * 1.5),
              DockGlassIconButton(
                icon: Icons.picture_in_picture_alt_rounded,
                tooltip: 'Picture in picture',
                onPressed: onPip!,
                metrics: metrics,
                palette: palette,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _bottomUnit(BuildContext context, List<_Tool> tools) {
    final pad = EdgeInsets.fromLTRB(
      metrics.padX * 1.8,
      metrics.padY,
      metrics.padX * 1.8,
      metrics.padY * 1.5,
    );
    return Container(
      // Just a shade for legibility — no box: the controls float on the
      // picture.
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xB3000000), Color(0x00000000)],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (infoPanel != null)
              onInfoPanelExtent == null
                  ? infoPanel!
                  : DockExtentReporter(
                      onExtent: onInfoPanelExtent!,
                      generation: infoPanelGeneration,
                      child: infoPanel!,
                    ),
            if (!hideOptions)
              Padding(
                padding: pad,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (arrangement == DockArrangement.wide && !hideSeekbar)
                      _scrubber(context, bleed: true),
                    switch (arrangement) {
                      DockArrangement.narrow => _narrow(context, tools),
                      DockArrangement.regular => _twoTier(context, tools),
                      DockArrangement.wide => _wide(context, tools),
                    },
                  ],
                ),
              )
            else if (!hideSeekbar)
              Padding(padding: pad, child: _scrubber(context)),
          ],
        ),
      ),
    );
  }

  /// The scrubber, then one row of round icon tools flush right; whatever
  /// doesn't fit goes to More. Transport lives in the middle of the screen.
  Widget _narrow(BuildContext context, List<_Tool> tools) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!hideSeekbar) _scrubber(context),
        SizedBox(height: metrics.gap * 0.5),
        LayoutBuilder(
          builder: (context, constraints) {
            final scaledLabel = MediaQuery.textScalerOf(
              context,
            ).scale(metrics.label);
            final chipW = math.max(
              metrics.target,
              metrics.icon + metrics.padY * 2 + 2,
            );
            final gap = metrics.gap * 0.75;
            // More is the one labelled chip; measure it rather than guess.
            final morePainter = TextPainter(
              text: TextSpan(
                text: 'More',
                style: TextStyle(
                  fontSize: scaledLabel,
                  fontWeight: FontWeight.w600,
                ),
              ),
              textDirection: TextDirection.ltr,
              maxLines: 1,
            )..layout();
            final moreW =
                metrics.icon +
                metrics.padX * 2 +
                metrics.gap * 0.75 +
                morePainter.width +
                4;
            morePainter.dispose();
            double width(int n, bool more) =>
                n * chipW +
                (n > 1 ? (n - 1) * gap : 0) +
                (more ? (n > 0 ? gap : 0) + moreW : 0);
            var count = tools.length;
            if (width(count, false) > constraints.maxWidth) {
              while (count > 0 && width(count, true) > constraints.maxWidth) {
                count--;
              }
            }
            final shown = tools.take(count).toList();
            final more = count < tools.length;
            return Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                for (var i = 0; i < shown.length; i++) ...[
                  if (i > 0) SizedBox(width: gap),
                  DockChip(
                    icon: shown[i].icon,
                    label: shown[i].value == null
                        ? shown[i].label
                        : '${shown[i].label} · ${shown[i].value}',
                    showLabel: false,
                    active: shown[i].active,
                    tint: shown[i].tint,
                    onPressed: shown[i].onPressed,
                    metrics: metrics,
                    palette: palette,
                  ),
                ],
                if (more) ...[
                  if (shown.isNotEmpty) SizedBox(width: gap),
                  DockChip(
                    icon: Icons.more_horiz_rounded,
                    label: 'More',
                    active: true,
                    onPressed: () => _openOverflow(context, tools),
                    metrics: metrics,
                    palette: palette,
                  ),
                ],
              ],
            );
          },
        ),
      ],
    );
  }

  /// Centred transport above the scrubber, tools below — capped at two rows.
  ///
  /// An uncapped `Wrap` is a wall: a session with every capability produced
  /// six rows of chips and a dock that ate the screen. Anything past two rows
  /// goes to More, the same escape the narrow arrangement uses.
  Widget _twoTier(BuildContext context, List<_Tool> tools) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!hideSeekbar) _scrubber(context),
        SizedBox(height: metrics.gap),
        LayoutBuilder(
          builder: (context, constraints) {
            final scaledLabel = MediaQuery.textScalerOf(
              context,
            ).scale(metrics.label);
            String labelFor(_Tool t) =>
                t.value == null ? t.label : '${t.label} · ${t.value}';
            double chipWidth(String text) =>
                metrics.icon +
                metrics.padX * 2 +
                metrics.gap * 0.75 +
                text.length * scaledLabel * 0.62;

            // Budget every slot against the WIDEST chip rather than each
            // chip's own estimate. `Wrap` re-lays by real width, so a
            // per-chip estimate that runs even slightly short yields a third
            // row — which is what shipped. Budgeting uniformly by the widest
            // can only ever show too few, never too many.
            var widest = metrics.icon + metrics.padX * 2 + 40;
            for (final tool in tools) {
              final w = chipWidth(labelFor(tool));
              if (w > widest) widest = w;
            }
            final perRow = (constraints.maxWidth / (widest + metrics.gap))
                .floor()
                .clamp(1, tools.length + 1);
            final capacity = perRow * 2;
            final shown = tools.length <= capacity
                ? tools
                : tools.take(capacity - 1).toList();

            return Wrap(
              spacing: metrics.gap,
              runSpacing: metrics.gap,
              alignment: WrapAlignment.center,
              children: [
                for (final tool in shown)
                  DockChip(
                    icon: tool.icon,
                    label: labelFor(tool),
                    active: tool.active,
                    tint: tool.tint,
                    onPressed: tool.onPressed,
                    metrics: metrics,
                    palette: palette,
                  ),
                if (shown.length < tools.length)
                  DockChip(
                    icon: Icons.more_horiz_rounded,
                    label: 'More',
                    active: true,
                    onPressed: () => _openOverflow(context, tools),
                    metrics: metrics,
                    palette: palette,
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _wide(BuildContext context, List<_Tool> tools) {
    // The tool cluster is icon-only chips, whose width is exact: a chip is
    // its icon plus padY each side plus its 1px border, never under the
    // touch target. Sizing the cluster to that — rather than giving it a
    // Flexible share of the bar — is what keeps it flush right: a loose
    // Flexible keeps whatever share it does not use as an empty strip at
    // the end of the row, and cuts its content at the left when the share
    // is too small.
    final chipW = math.max(metrics.target, metrics.icon + metrics.padY * 2 + 2);
    final gapW = metrics.gap * 0.75;
    final chips = <Widget>[
      for (final tool in tools)
        DockChip(
          icon: tool.icon,
          label: tool.value == null
              ? tool.label
              : '${tool.label} · ${tool.value}',
          showLabel: false,
          active: tool.active,
          tint: tool.tint,
          onPressed: tool.onPressed,
          metrics: metrics,
          palette: palette,
        ),
      if (showFullscreen && onFullscreen != null)
        DockChip(
          icon: Icons.fullscreen_rounded,
          label: 'Fullscreen',
          showLabel: false,
          onPressed: onFullscreen!,
          metrics: metrics,
          palette: palette,
        ),
    ];
    // Spacers only BETWEEN chips — a trailing one was the gap at the right.
    final cluster = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < chips.length; i++) ...[
          if (i > 0) SizedBox(width: gapW),
          chips[i],
        ],
      ],
    );
    final need = chips.isEmpty
        ? 0.0
        : chips.length * chipW + (chips.length - 1) * gapW;

    return LayoutBuilder(
      builder: (context, constraints) {
        // The tools get what the time readout leaves (the volume bar is the
        // one thing on the left that shrinks), and scroll past that.
        final scaledLabel = MediaQuery.textScalerOf(
          context,
        ).scale(metrics.label);
        // Transport sits mid-screen now; the left zone is volume + time.
        const transportW = 0.0;
        // The widest readout this session can show, measured, not guessed.
        final timePainter = TextPainter(
          text: TextSpan(
            text: '88:88:88  /  88:88:88',
            style: TextStyle(
              fontSize: scaledLabel,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        final timeW = timePainter.width;
        timePainter.dispose();
        // The gaps around the time and before the tools.
        final leftNeed = transportW + timeW + metrics.gap * 2.5 + 2;
        final cap = constraints.maxWidth.isFinite
            ? math.max(chipW, constraints.maxWidth - leftNeed)
            : need;
        final Widget toolsZone;
        if (chips.isEmpty) {
          toolsZone = const SizedBox.shrink();
        } else if (need <= cap) {
          toolsZone = cluster;
        } else {
          // Genuinely too many: a fixed-width strip that keeps the LAST
          // tools visible and fades out at its left edge, so the cut reads
          // as "there is more" rather than a rendering fault.
          toolsZone = SizedBox(
            width: cap,
            child: ShaderMask(
              shaderCallback: (rect) => const LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0x00000000), Color(0xFF000000)],
                stops: [0.0, 0.08],
              ).createShader(rect),
              blendMode: BlendMode.dstIn,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: cluster,
              ),
            ),
          );
        }
        // The left zone takes what the tools leave; inside it only the
        // volume bar gives way, so transport and time never get cut.
        return Row(
          children: [
            Expanded(
              child: Row(
                children: [
                  if (onVolumeChanged != null) ...[
                    Flexible(child: _volume(context)),
                    SizedBox(width: metrics.gap),
                  ],
                  _timeReadout(),
                ],
              ),
            ),
            if (chips.isNotEmpty) SizedBox(width: metrics.gap * 1.5),
            toolsZone,
          ],
        );
      },
    );
  }

  /// Speaker plus a short level bar — what anchors the play button so the
  /// left of the row reads as an instrument instead of a void.
  Widget _volume(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          volume <= 0.01
              ? Icons.volume_off_rounded
              : volume < 0.5
              ? Icons.volume_down_rounded
              : Icons.volume_up_rounded,
          size: metrics.icon,
          color: palette.ink,
        ),
        Flexible(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: metrics.target * 2.4),
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: metrics.trackHeight * 0.75,
                activeTrackColor: palette.ink,
                inactiveTrackColor: palette.inactiveTrack,
                thumbColor: palette.ink,
                thumbShape: RoundSliderThumbShape(
                  enabledThumbRadius: metrics.knob * 0.35,
                ),
                overlayShape: RoundSliderOverlayShape(
                  overlayRadius: metrics.knob * 0.7,
                ),
              ),
              child: Slider(
                min: 0,
                max: 1,
                value: volume.clamp(0.0, 1.0),
                onChanged: onVolumeChanged,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _timeReadout() {
    return ValueListenableBuilder<PlaybackUiClockValue>(
      valueListenable: clock,
      builder: (context, value, _) => Text(
        '${_fmt(value.position)}  /  ${_fmt(value.duration)}',
        maxLines: 1,
        style: TextStyle(
          color: palette.inkDim,
          fontSize: metrics.label,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  List<Widget> _transport() {
    return [
      if (hasPrevious && onPrevious != null) ...[
        DockTransportButton(
          icon: Icons.skip_previous_rounded,
          label: 'Previous',
          onPressed: onPrevious!,
          metrics: metrics,
          palette: palette,
        ),
        SizedBox(width: metrics.gap * 4),
      ],
      DockTransportButton(
        icon: isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
        label: isPlaying ? 'Pause' : 'Play',
        onPressed: onPlayPause,
        primary: true,
        metrics: metrics,
        palette: palette,
      ),
      if (hasNext && onNext != null) ...[
        SizedBox(width: metrics.gap * 4),
        DockTransportButton(
          icon: Icons.skip_next_rounded,
          label: 'Next',
          onPressed: onNext!,
          metrics: metrics,
          palette: palette,
        ),
      ],
    ];
  }

  Widget _scrubber(BuildContext context, {bool bleed = false}) {
    return ValueListenableBuilder<PlaybackUiClockValue>(
      valueListenable: clock,
      builder: (context, value, _) => _scrubberRow(context, value, bleed),
    );
  }

  Widget _scrubberRow(
    BuildContext context,
    PlaybackUiClockValue value,
    bool bleed,
  ) {
    final total = value.duration.inMilliseconds <= 0
        ? 1
        : value.duration.inMilliseconds;
    final progress = (value.position.inMilliseconds / total).clamp(0.0, 1.0);

    final bar = SliderTheme(
      data: SliderTheme.of(context).copyWith(
        trackHeight: metrics.trackHeight,
        // deep -> hot with a bloom at the played edge. Material's flat
        // activeTrackColor cannot express this.
        trackShape: GradientSliderTrackShape(
          deep: palette.deep,
          hot: palette.hot,
          inactive: palette.inactiveTrack,
          glow: palette.glow,
        ),
        thumbColor: palette.ink,
        thumbShape: RoundSliderThumbShape(enabledThumbRadius: metrics.knob / 2),
        overlayShape: RoundSliderOverlayShape(
          overlayRadius: metrics.knob * 0.8,
        ),
        overlayColor: palette.activeFill,
      ),
      child: Slider(
        min: 0,
        max: 1,
        value: progress,
        onChangeStart: (_) => onSeekBarChangedStart(),
        onChanged: onSeekBarChanged,
        onChangeEnd: (_) => onSeekBarChangeEnd(),
      ),
    );

    // Wide runs the bar edge to edge and moves the readouts into the left
    // zone; the narrower arrangements keep them flanking it.
    if (bleed) return SizedBox(height: metrics.target, child: bar);

    return SizedBox(
      height: DockLayoutInput.scrubberH,
      child: Row(
        children: [
          Flexible(
            child: Text(
              _fmt(value.position),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.ink,
                fontSize: metrics.label,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
          SizedBox(width: metrics.gap),
          Expanded(flex: 8, child: bar),
          SizedBox(width: metrics.gap),
          Flexible(
            child: Text(
              _fmt(value.duration),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: palette.ink,
                fontSize: metrics.label,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _openOverflow(BuildContext context, List<_Tool> tools) {
    DockOverflowSheet.show(
      context,
      palette: palette,
      metrics: metrics,
      actions: [
        for (final tool in tools)
          DockOverflowAction(
            icon: tool.icon,
            label: tool.label,
            value: tool.value,
            active: tool.active,
            onPressed: tool.onPressed,
          ),
      ],
    );
  }
}
