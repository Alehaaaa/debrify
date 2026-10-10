import 'dart:async';
import 'package:flutter/material.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/stremio_addon.dart';
import '../services/debrify_image_cache.dart';
import '../services/discover_prefs.dart';
import '../services/download_service.dart';
import '../services/downloaded_media_service.dart';
import '../services/downloads/title_download_summary.dart';
import '../services/offline_title_store.dart';
import '../services/storage_service.dart';
import '../services/stremio_service.dart';
import '../services/trakt/trakt_episode_model.dart';
import '../services/watched_action_coordinator.dart';
import '../services/watched_status_service.dart';
import '../theme/app_theme_controller.dart';
import '../theme/app_theme_scope.dart';
import '../services/downloads/pending_title_downloads.dart';
import '../theme/shipped_themes.dart' show effectiveDetailTheme;
import '../theme/theme_core_resolver.dart';
import '../theme/theme_overrides.dart';
import '../utils/artwork_url.dart';
import '../widgets/card_action_menu.dart';
import '../models/downloaded_media.dart';
import '../widgets/detail/detail_identity.dart';
import '../widgets/detail/detail_resume_choice.dart';
import '../widgets/detail/detail_style.dart';
import '../widgets/detail/theme/detail_theme.dart';
import '../widgets/home/home_theme.dart';
import '../widgets/see_all/discover_card_settings_scope.dart';
import '../widgets/see_all/see_all_filter_bar.dart';
import '../widgets/see_all/see_all_poster_grid.dart';
import '../widgets/see_all/stremio_dropdown.dart';
import 'download_manager_screen.dart';
import 'merged_series_detail_screen.dart';
export 'download_manager_screen.dart' hide DownloadManagerScreen;

enum _DownloadCardAction {
  play,
  open,
  files,
  markWatched,
  markUnwatched,
  fixMatch,
  resetMatch,
  pause,
  resume,
  retry,
  delete,
}

/// Downloads library: Home's page wash, header typography and white glass
/// controls around Discover's own filter bar, poster grid and card settings.
class DownloadsScreen extends StatefulWidget {
  @visibleForTesting
  final Future<List<LocalDownload>> Function()? loadDownloads;
  const DownloadsScreen({super.key, this.loadDownloads});
  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}

class _DownloadsScreenState extends State<DownloadsScreen> {
  List<LocalDownload> _items = [];
  final Map<String, double> _progress = {};

  /// How far into each title the user is (0..1), by library group key — the
  /// same thin white bar Home's tiles carry. Read from this device only.
  Map<String, double> _watched = const {};
  int _watchedGeneration = 0;
  String _watchedSignature = '';
  StreamSubscription? _status, _moves, _progressSub;
  Timer? _folderPoll;
  // The empty local library is immediately useful; a scan can populate it
  // without pretending a network request is in progress.
  bool _loading = false;
  String? _error;
  String _filter = 'All', _availability = 'All';
  int _generation = 0;
  @override
  void initState() {
    super.initState();
    _status = DownloadService.instance.statusStream.listen((_) => _refresh());
    _moves = DownloadService.instance.moveProgressStream.listen((e) {
      if (e.done || e.failed) _refresh();
    });
    _progressSub = DownloadService.instance.progressStream.listen((e) {
      if (!mounted || e.progress < 0) return;
      if (((_progress[e.task.taskId] ?? -1) * 100).floor() ==
          (e.progress * 100).floor()) {
        return;
      }
      setState(() => _progress[e.task.taskId] = e.progress);
    });
    // Desktop and iOS do not provide a portable directory-watch API. A small
    // polling interval keeps files copied in or removed externally reflected
    // in the library without waiting for a download queue event.
    _folderPoll = Timer.periodic(const Duration(seconds: 4), (_) => _refresh());
    _pendingSeen = PendingTitleDownloads.entries.value.keys.toSet();
    PendingTitleDownloads.entries.addListener(_onPendingChanged);
    _refresh();
  }

  /// Automatic downloads still finding their source show as posters too.
  /// When one leaves the list its real task usually just appeared — reload
  /// so the tile hands over to the progress sweep without a gap.
  Set<String> _pendingSeen = const {};
  void _onPendingChanged() {
    if (!mounted) return;
    final now = PendingTitleDownloads.entries.value.keys.toSet();
    final ended = _pendingSeen.difference(now).isNotEmpty;
    _pendingSeen = now;
    setState(() {});
    if (ended) _refresh();
  }

  Future<void> _showPendingOptions(PendingTitleDownload pending) async {
    final cancel = pending.onCancel;
    if (cancel == null) return;
    final stop = await showModalBottomSheet<bool>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(pending.title),
              subtitle: Text(pending.phase.label),
            ),
            ListTile(
              leading: const Icon(Icons.close_rounded),
              title: const Text('Stop download'),
              onTap: () => Navigator.of(sheetContext).pop(true),
            ),
          ],
        ),
      ),
    );
    if (stop == true) cancel();
  }

  Future<void> _refresh() async {
    final generation = ++_generation;
    try {
      final items =
          await (widget.loadDownloads?.call() ??
              DownloadedMediaService.load(includeTransfers: true));
      if (mounted && generation == _generation) {
        setState(() {
          _items = items;
          _loading = false;
          _error = null;
        });
        // The folder poll lands here every few seconds; only re-read watch
        // progress when the set of finished files actually changed.
        final signature = (items.where((e) => e.isReady).map(
          (e) => '${e.groupKey}|${e.location}',
        ).toList()..sort()).join(',');
        if (signature != _watchedSignature) {
          _watchedSignature = signature;
          unawaited(_loadWatched());
        }
      }
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = 'Could not load downloads. Try refreshing.';
        });
      }
    }
  }

  Future<void> _loadWatched() async {
    final generation = ++_watchedGeneration;
    final groups = <String, List<LocalDownload>>{};
    for (final item in _items) {
      if (!item.isReady || item.media?.isCatalogLinked != true) continue;
      groups.putIfAbsent(item.groupKey, () => []).add(item);
    }
    final next = <String, double>{};
    for (final entry in groups.entries) {
      try {
        final fraction = await downloadedWatchFraction(
          entry.value.first.media!,
          sortDownloads(entry.value),
        );
        if (fraction != null) next[entry.key] = fraction;
      } catch (_) {
        // One unreadable record must not hide every other title's bar.
      }
    }
    if (!mounted || generation != _watchedGeneration) return;
    setState(() => _watched = next);
  }

  @override
  void dispose() {
    _status?.cancel();
    _moves?.cancel();
    _progressSub?.cancel();
    _folderPoll?.cancel();
    PendingTitleDownloads.entries.removeListener(_onPendingChanged);
    super.dispose();
  }

  Future<void> _manage() async {
    await openDownloadManager(context);
    _refresh();
  }

  TitleDownloadSummary _summary(List<LocalDownload> items) =>
      TitleDownloadSummary.of(items, live: _progress);

  bool _menuOpen = false;

  /// Hold / right-click on a library poster: play the download, open it, look
  /// at its files, steer the transfers still running, or delete it.
  Future<void> _showOptions(
    StremioMeta poster,
    List<LocalDownload> group,
  ) async {
    if (_menuOpen) return;
    _menuOpen = true;
    final ready = sortDownloads(group.where((e) => e.isReady));
    final pending = group.where((e) => !e.isReady).toList();
    final running = [
      for (final e in pending)
        if (e.record.status == TaskStatus.running ||
            e.record.status == TaskStatus.enqueued ||
            e.record.status == TaskStatus.waitingToRetry)
          e,
    ];
    final paused = [
      for (final e in pending)
        if (e.record.status == TaskStatus.paused) e,
    ];
    final failed = [
      for (final e in pending)
        if (e.record.status == TaskStatus.failed) e,
    ];
    final series = group.first.media?.type == 'series';
    final homeDetail = opensHomeDetail(group);
    final first = ready.isEmpty ? null : ready.first.media;
    final firstEpisode =
        series && first?.season != null && first?.episode != null
        ? 'S${first!.season.toString().padLeft(2, '0')}'
              'E${first.episode.toString().padLeft(2, '0')}'
        : null;
    final summary = _summary(group);
    // Watched state for catalog-linked titles (same identity the poster ticks
    // read), so the menu offers the mark that applies.
    final media = group.first.media;
    final watchedId = media != null && media.isCatalogLinked ? media.id : null;
    WatchedStatusService.instance.ensureStarted();
    final watched =
        watchedId != null &&
        WatchedStatusService.instance.isWatchedForTicks(
          watchedId,
          series ? 'series' : 'movie',
        );
    _DownloadCardAction? action;
    try {
      var manualMatch = false;
      try {
        manualMatch = await DownloadedMediaService.hasManualMatch(group);
      } catch (_) {}
      if (!mounted) return;
      action = await showCardActionMenu<_DownloadCardAction>(
        context,
        title: poster.name,
        isTelevision: false,
        posterUrl: poster.poster,
        subtitle: [
          if (group.length > 1) '${group.length} files',
          summary.inFlight
              ? (summary.status ?? 'Downloading')
              : 'On this device',
        ].join('  ·  '),
        actions: [
          if (ready.isNotEmpty)
            CardMenuAction(
              value: _DownloadCardAction.play,
              icon: Icons.play_arrow_rounded,
              label: firstEpisode == null ? 'Play' : 'Play $firstEpisode',
              description: series
                  ? 'Start the first downloaded episode, offline.'
                  : 'Play the downloaded file, offline.',
            ),
          CardMenuAction(
            value: _DownloadCardAction.open,
            icon: homeDetail
                ? Icons.info_outline_rounded
                : Icons.folder_open_rounded,
            label: homeDetail ? 'Details' : 'Open download',
            description: homeDetail
                ? 'The title page, with Play wired to the files on this device.'
                : 'Every file of this download and its progress.',
          ),
          if (homeDetail)
            CardMenuAction(
              value: _DownloadCardAction.files,
              icon: Icons.folder_open_rounded,
              label: 'Downloaded files',
              description: series
                  ? 'Each downloaded episode, with its size and progress.'
                  : 'The file on this device, with its size.',
            ),
          if (watchedId != null)
            watched
                ? CardMenuAction(
                    value: _DownloadCardAction.markUnwatched,
                    icon: Icons.remove_done_rounded,
                    label: 'Mark as unwatched',
                    description:
                        'Clears the watched mark here and on your synced '
                        'trackers.',
                  )
                : CardMenuAction(
                    value: _DownloadCardAction.markWatched,
                    icon: Icons.done_all_rounded,
                    label: series ? 'Mark series as watched' : 'Mark as watched',
                    description:
                        'Marks it watched and clears any resume position, here '
                        'and on your synced trackers.',
                  ),
          CardMenuAction(
            value: _DownloadCardAction.fixMatch,
            icon: Icons.manage_search_rounded,
            label: 'Fix match',
            description: group.first.media?.isCatalogLinked == true
                ? 'Wrong title? Search for the right one and refile it.'
                : 'Find the title this is, for its art, details and '
                      'episodes.',
          ),
          if (manualMatch)
            const CardMenuAction(
              value: _DownloadCardAction.resetMatch,
              icon: Icons.undo_rounded,
              label: 'Reset match',
              description:
                  'Forget the title you picked and use what the download '
                  'says.',
            ),
          if (running.isNotEmpty)
            CardMenuAction(
              value: _DownloadCardAction.pause,
              icon: Icons.pause_rounded,
              label: 'Pause',
              description: running.length == 1
                  ? 'Pause this download. Resume it any time.'
                  : 'Pause the ${running.length} downloads still running.',
            ),
          if (paused.isNotEmpty)
            CardMenuAction(
              value: _DownloadCardAction.resume,
              icon: Icons.play_circle_outline_rounded,
              label: 'Resume',
              description: paused.length == 1
                  ? 'Carry on from where this download stopped.'
                  : 'Carry on with the ${paused.length} paused downloads.',
            ),
          if (failed.isNotEmpty)
            CardMenuAction(
              value: _DownloadCardAction.retry,
              icon: Icons.refresh_rounded,
              label: 'Retry',
              description: failed.length == 1
                  ? 'Restart the download that failed.'
                  : 'Restart the ${failed.length} downloads that failed.',
            ),
          CardMenuAction(
            value: _DownloadCardAction.delete,
            icon: Icons.delete_outline_rounded,
            label: group.length == 1
                ? 'Delete download'
                : 'Delete ${group.length} downloads',
            description:
                'Removes it from this device. You can download it '
                'again later.',
            destructive: true,
          ),
        ],
      );
    } finally {
      _menuOpen = false;
    }
    if (!mounted || action == null) return;
    switch (action) {
      case _DownloadCardAction.play:
        try {
          await DownloadedMediaService.play(context, ready.first);
        } catch (_) {
          _snack('Could not open this download.');
        }
      case _DownloadCardAction.open:
        await openDownloadedItem(context, group);
      case _DownloadCardAction.files:
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => DownloadedTitleScreen(items: group),
          ),
        );
      case _DownloadCardAction.markWatched:
      case _DownloadCardAction.markUnwatched:
        if (watchedId == null) break;
        final mark = action == _DownloadCardAction.markWatched;
        final result = await WatchedActionCoordinator.setTitleWatched(
          imdbId: watchedId,
          contentType: series ? 'series' : 'movie',
          watched: mark,
        );
        WatchedStatusService.instance.refresh();
        if (!mounted) break;
        _snack(
          result.success
              ? (mark ? 'Marked as watched' : 'Marked as unwatched')
              : 'Saved on this device, but ${result.failedTargets.join(', ')} '
                    'didn\'t update',
        );
      case _DownloadCardAction.fixMatch:
        final picked = await showFixMatchDialog(
          context,
          initialQuery: group.first.media?.isCatalogLinked == true
              ? poster.name
              : _searchableName(group.first),
        );
        if (picked == null || !mounted) break;
        final id = picked.effectiveImdbId ?? picked.id;
        try {
          await DownloadedMediaService.rematch(
            group,
            id: id,
            title: picked.name,
            type: picked.type == 'series' ? 'series' : 'movie',
            poster: picked.poster,
            year: picked.year,
          );
          _snack('Filed under ${picked.name}');
        } catch (_) {
          _snack('Couldn\'t save the match. Try again.');
        }
      case _DownloadCardAction.resetMatch:
        try {
          await DownloadedMediaService.resetMatch(group);
          _snack('Match reset');
        } catch (_) {
          _snack('Couldn\'t reset the match. Try again.');
        }
      case _DownloadCardAction.pause:
        for (final e in running) {
          try {
            await DownloadService.instance.pause(e.record.task);
          } catch (_) {}
        }
      case _DownloadCardAction.resume:
      case _DownloadCardAction.retry:
        var ok = true;
        for (final e
            in action == _DownloadCardAction.resume ? paused : failed) {
          try {
            ok = await DownloadService.instance.resume(e.record.task) && ok;
          } catch (_) {
            ok = false;
          }
        }
        if (!ok) _snack('Could not restart every download. Try again later.');
      case _DownloadCardAction.delete:
        await _deleteGroup(poster.name, group);
    }
    if (mounted) _refresh();
  }

  Future<void> _deleteGroup(String title, List<LocalDownload> group) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          group.length == 1
              ? 'Delete download?'
              : 'Delete ${group.length} downloads?',
        ),
        content: Text(
          group.length == 1
              ? 'Delete “$title” from this device? You can download it again later.'
              : 'Delete every downloaded file of “$title” from this device? '
                    'You can download them again later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    var failed = false;
    try {
      // Same profile recheck as the download page: only touch queue records
      // the active profile owns. (Scanned files were already filtered.)
      final owned = {
        for (final record in await DownloadService.instance.allRecords())
          record.taskId,
      };
      for (final item in group) {
        if (!item.isScanned && !owned.contains(item.record.taskId)) continue;
        try {
          await DownloadedMediaService.remove(item);
        } catch (_) {
          failed = true;
        }
      }
    } catch (_) {
      failed = true;
    }
    if (failed) _snack('Could not remove every file. Try again.');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    final groups = <String, List<LocalDownload>>{};
    for (final item in _items) {
      final category = item.media == null
          ? 'Files'
          : item.media!.type == 'series'
          ? 'Shows'
          : 'Movies';
      if (_filter != 'All' && _filter != category) continue;
      if (_availability == 'Downloaded' && !item.isReady) continue;
      if (_availability == 'Downloading' && item.isReady) continue;
      groups.putIfAbsent(item.groupKey, () => []).add(item);
    }
    // Keyed like a title's files ('type:id'), so a series already holding
    // episodes shows the next one's search on its existing poster.
    final pendingByKey = <String, PendingTitleDownload>{
      for (final p in PendingTitleDownloads.entries.value.values)
        if ((_filter == 'All' ||
                _filter == (p.type == 'series' ? 'Shows' : 'Movies')) &&
            _availability != 'Downloaded')
          '${p.type}:${p.id}': p,
    };
    final posters = [
      for (final entry in pendingByKey.entries)
        if (!groups.containsKey(entry.key))
          StremioMeta(
            id: entry.key,
            type: entry.value.type,
            name: entry.value.title,
            poster: entry.value.poster,
            year: entry.value.year,
          ),
      for (final entry in groups.entries)
        StremioMeta(
          id: entry.key,
          type: entry.value.first.media?.type ?? 'movie',
          name: entry.value.first.title,
          poster: entry.value.first.media?.poster,
          year: entry.value.first.media?.year,
        ),
    ];
    final metrics = HomeTheme.metricsOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: app.home.bg, gradient: app.home.wash),
      child: SafeArea(
        bottom: false,
        child: Column(
          children: [
            // Home's section-header typography, laid out so the title keeps
            // its full width beside the controls.
            Padding(
              padding: EdgeInsets.fromLTRB(
                metrics.sectionHPadding,
                metrics.sectionVPadding + 14,
                metrics.sectionHPadding,
                metrics.sectionVPadding + 4,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        text: 'Downloads',
                        children: [
                          if (posters.isNotEmpty)
                            TextSpan(
                              text: '   ${posters.length}',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.32),
                                fontSize: metrics.headerFontSize - 2,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.2,
                              ),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: metrics.headerFontSize + 4,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.6,
                        height: 1.1,
                      ),
                    ),
                  ),
                  _GlassIconButton(
                    tooltip: 'Refresh library',
                    icon: Icons.refresh_rounded,
                    onTap: _refresh,
                  ),
                  const SizedBox(width: 10),
                  _GlassIconButton(
                    tooltip: 'Manage downloads',
                    icon: Icons.tune_rounded,
                    onTap: _manage,
                  ),
                ],
              ),
            ),
            SeeAllFilterBar(
              isTelevision: false,
              activeCount:
                  (_filter == 'All' ? 0 : 1) + (_availability == 'All' ? 0 : 1),
              buildChips: () => [
                StremioDropdown<String>(
                  label: 'Type',
                  value: _filter,
                  options: [
                    for (final value in ['All', 'Movies', 'Shows', 'Files'])
                      StremioDropdownOption(value, value),
                  ],
                  onSelected: (value) => setState(() => _filter = value),
                ),
                StremioDropdown<String>(
                  label: 'Status',
                  value: _availability,
                  options: [
                    for (final value in ['All', 'Downloaded', 'Downloading'])
                      StremioDropdownOption(value, value),
                  ],
                  onSelected: (value) => setState(() => _availability = value),
                ),
              ],
            ),
            Expanded(
              // The page runs under the tab bar on iOS; keep the grid's last
              // row clear of it.
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.paddingOf(context).bottom,
                ),
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(color: Colors.white),
                      )
                    : _error != null || posters.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.download_rounded,
                              size: 44,
                              color: Colors.white.withValues(alpha: 0.32),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              _error ?? 'No downloads yet',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              'Use Download on a title to keep it on this device.',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.55),
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 18),
                            _GlassPillButton(
                              icon: Icons.tune_rounded,
                              label: 'Open download manager',
                              onTap: _manage,
                            ),
                          ],
                        ),
                      )
                    : DiscoverCardSettingsScope(
                        showTypeTags: DiscoverPrefs.showTypeTags,
                        showRatings: DiscoverPrefs.showRatings,
                        showTitles: DiscoverPrefs.showTitles,
                        child: SeeAllPosterGrid(
                          localOnly: true,
                          items: posters,
                          isTelevision: false,
                          loadingMore: false,
                          exhausted: true,
                          onLoadMore: () {},
                          progressOf: (item) => _watched[item.id],
                          downloadOf: (item) {
                            final pending = pendingByKey[item.id];
                            if (pending != null) {
                              // Negative: preparing, no percentage yet.
                              return (value: -1, status: pending.phase.label);
                            }
                            final summary = _summary(groups[item.id]!);
                            return summary.inFlight
                                ? (
                                    value: summary.progress!,
                                    status: summary.status,
                                  )
                                : null;
                          },
                          onOpen: (item) async {
                            final group = groups[item.id];
                            if (group == null) {
                              final pending = pendingByKey[item.id];
                              if (pending != null) {
                                await _showPendingOptions(pending);
                              }
                              return;
                            }
                            await openDownloadedItem(context, group);
                            _refresh();
                            // Back from the detail page, likely from playing:
                            // the bar must show where they stopped.
                            unawaited(_loadWatched());
                          },
                          onOptions: (item) {
                            final group = groups[item.id];
                            final pending = pendingByKey[item.id];
                            if (group != null) {
                              unawaited(_showOptions(item, group));
                            } else if (pending != null) {
                              unawaited(_showPendingOptions(pending));
                            }
                          },
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> openDownloadManager(BuildContext context) =>
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: const Text('Download manager')),
          body: const DownloadManagerScreen(),
        ),
      ),
    );

/// Whether a library entry opens the full Home detail page (a catalog title
/// with at least one finished file) rather than the download page.
@visibleForTesting
bool opensHomeDetail(List<LocalDownload> group) =>
    group.first.media?.isCatalogLinked == true && group.any((e) => e.isReady);

/// Opens a library entry. A catalog title with a finished download gets the
/// same detail page Home opens, with Play wired to the local files; its
/// Download button leads on to the download page. Anything else (unlinked
/// files, transfers that haven't finished) opens the download page directly.
Future<void> openDownloadedItem(
  BuildContext context,
  List<LocalDownload> group,
) async {
  if (!opensHomeDetail(group)) {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DownloadedTitleScreen(items: group),
      ),
    );
    return;
  }
  final media = group.first.media!;
  final ready = sortDownloads(group.where((e) => e.isReady));
  final addon = await _metadataAddon();
  // The library only knows the small shelf poster the download was started
  // with. The page's hero wants the title's full art, which is kept with the
  // download — use it from the first frame (and offline).
  final store = OfflineTitleStore.instance;
  final savedMeta = await store.read(
    media.id,
    '${OfflineTitleStore.meta}:${media.type}',
  );
  final saved =
      PageSnapshot.fromJson(
        await store.read(media.id, OfflineTitleStore.page),
      )?.meta ??
      (savedMeta is Map
          ? StremioMeta.fromJson(Map<String, dynamic>.from(savedMeta))
          : null);
  if (!context.mounted) return;

  Future<void> playFallback(
    BuildContext ctx, {
    int? season,
    int? episode,
  }) async {
    // The detail page tries the matching local file first; this runs when
    // there isn't one. A specific episode that isn't on the device says so;
    // a general Play starts the first downloaded file.
    if (season != null && episode != null && media.type == 'series') {
      final local = ready
          .where(
            (item) =>
                item.media?.season == season && item.media?.episode == episode,
          )
          .firstOrNull;
      if (local != null) {
        await DownloadedMediaService.play(ctx, local);
        return;
      }
      ScaffoldMessenger.of(ctx).showSnackBar(
        SnackBar(
          content: Text(
            'S${season.toString().padLeft(2, '0')} · '
            'E${episode.toString().padLeft(2, '0')} isn’t downloaded.',
          ),
        ),
      );
      return;
    }
    await DownloadedMediaService.play(ctx, ready.first);
  }

  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (routeContext) => MergedDetailScreen(
        // Keep the Downloads entry on the exact same details surface as Home.
        // The episode filter below is the offline constraint; a separate
        // local-only page made downloaded shows look unlike downloaded movies
        // and hid Home's metadata, trailer and related-title treatment.
        item:
            saved ??
            StremioMeta(
              id: media.id,
              imdbId: media.id.startsWith('tt') ? media.id : null,
              type: media.type,
              name: media.title,
              poster: media.poster,
              year: media.year,
            ),
        addon: addon,
        seasonsLoader: media.type == 'series'
            ? () => downloadedSeasons(ready)
            : null,
        watchProgressLoader: () =>
            StorageService.getEpisodeWatchProgressByImdbId(media.id),
        onPlayEpisode: (episode) => playFallback(
          routeContext,
          season: episode.season,
          episode: episode.number,
        ),
        // Details and artwork come from the saved snapshot. Online refresh
        // belongs to the background offline-store warm, not this local page.
        // Only the episodes on the device, not the whole series.
        episodeFilter: media.type == 'series'
            ? (season, episode) => ready.any(
                (e) => e.media?.season == season && e.media?.episode == episode,
              )
            : null,
        initialSeason: ready.first.media?.season,
        initialEpisode: ready.first.media?.episode,
        // Read from this device only, so the button says "Continue 21:44"
        // in airplane mode exactly as it does online.
        resumeInfoLoader: () => downloadedResumeInfo(media, ready),
        onResume: (promised) => playFallback(
          routeContext,
          season: promised?.season,
          episode: promised?.episode,
        ),
        onQuickPlay: (selection) => playFallback(
          routeContext,
          season: selection.season,
          episode: selection.episode,
        ),
        // A downloaded title still has a full metadata graph. Keep its
        // people, studios and universe links alive, and let the user inspect
        // a related title even when that related title is not on the device.
        recommendationsLoader: media.id.startsWith('tt')
            ? () => StremioService.instance.getRecommendations(
                imdbId: media.id,
                type: media.type,
              )
            : null,
        metaEnricher: (id, type) =>
            StremioService.instance.fetchMetaDetails(imdbId: id, type: type),
        onRecommendationTap: (item) {
          unawaited(_openDownloadedCatalogPreview(routeContext, item));
        },
      ),
    ),
  );
}

/// Where a downloaded title's Continue button lands, from progress saved on
/// this device: a movie with a saved position, or the most recently watched
/// downloaded episode that is still in progress. Falls back to the first
/// downloaded episode, not started.
@visibleForTesting
Future<({bool started, int? season, int? episode})> downloadedResumeInfo(
  DownloadedMedia media,
  List<LocalDownload> ready,
) async {
  final latest = await _latestDownloadedProgress(media, ready);
  if (latest != null) {
    return (started: true, season: latest.season, episode: latest.episode);
  }
  if (media.type != 'series') {
    return (started: false, season: null, episode: null);
  }
  final first = ready.isEmpty ? null : ready.first.media;
  return (started: false, season: first?.season, episode: first?.episode);
}

/// How far into a downloaded title the user is (0..1) for its library tile:
/// the movie, or the most recently watched downloaded episode still in
/// progress. Null when nothing is in progress.
@visibleForTesting
Future<double?> downloadedWatchFraction(
  DownloadedMedia media,
  List<LocalDownload> ready,
) async {
  final latest = await _latestDownloadedProgress(media, ready);
  if (latest == null) return null;
  final position = (latest.state['positionMs'] as num?)?.toInt() ?? 0;
  final duration = (latest.state['durationMs'] as num?)?.toInt() ?? 0;
  if (duration <= 0) return null;
  return (position / duration).clamp(0.0, 1.0);
}

/// The in-progress saved position for a downloaded title: the movie's, or
/// the most recently updated one among its downloaded episodes.
Future<({int? season, int? episode, Map<String, dynamic> state})?>
_latestDownloadedProgress(
  DownloadedMedia media,
  List<LocalDownload> ready,
) async {
  if (media.type != 'series') {
    final state = await StorageService.getVideoPlaybackStateByImdbId(media.id);
    if (resumeTimestampFrom(state) == null) return null;
    return (season: null, episode: null, state: state!);
  }
  final progress = await StorageService.getMergedEpisodeProgress(
    seriesTitle: media.title,
    imdbId: media.id,
  );
  ({int? season, int? episode, Map<String, dynamic> state})? latest;
  var latestAt = -1;
  for (final item in ready) {
    final season = item.media?.season;
    final episode = item.media?.episode;
    if (season == null || episode == null) continue;
    final state = progress['${season}_$episode'];
    if (resumeTimestampFrom(state) == null) continue;
    final at = (state!['updatedAt'] as num?)?.toInt() ?? 0;
    if (at > latestAt) {
      latestAt = at;
      latest = (season: season, episode: episode, state: state);
    }
  }
  return latest;
}

/// The user's Cinemeta install when present, else the stock one — the
/// detail page only needs it for metadata.
/// Every available file remains reachable even without a cached episode list.
@visibleForTesting
Future<List<TraktSeason>> downloadedSeasons(List<LocalDownload> items) async {
  if (items.isEmpty) return const [];
  final id = items.first.media?.id;
  final saved = await OfflineTitleStore.instance.read(
    id,
    OfflineTitleStore.videos,
  );
  final videos = saved is List
      ? saved.whereType<Map>().toList()
      : const <Map>[];
  final seasons = <int, Map<int, TraktEpisode>>{};
  for (final item in items.where((item) => item.isReady)) {
    final media = item.media;
    final season = media?.season;
    final number = media?.episode;
    if (season == null || number == null) continue;
    final info = videos
        .where(
          (video) =>
              video['season'] == season &&
              (video['episode'] ?? video['number']) == number,
        )
        .firstOrNull;
    seasons.putIfAbsent(season, () => {})[number] = TraktEpisode(
      season: season,
      number: number,
      title: info?['title'] as String? ?? 'Episode $number',
      overview: info?['overview'] as String?,
      thumbnailUrl: info?['thumbnail'] as String?,
    );
  }
  return [
    for (final entry in seasons.entries)
      TraktSeason(
        number: entry.key,
        episodeCount: entry.value.length,
        episodes: entry.value.values.toList()
          ..sort((a, b) => a.number.compareTo(b.number)),
      ),
  ]..sort(seasonsSpecialsLast);
}

Future<StremioAddon> _metadataAddon() => OfflineTitleStore.cinemetaAddon();

/// Opens metadata reached from a downloaded title (a similar title or a
/// franchise entry). It deliberately stays in the Downloads flow: playback is
/// offered when the title is available locally, while metadata browsing and
/// the person/studio Discover links remain useful for every catalog title.
Future<void> _openDownloadedCatalogPreview(
  BuildContext context,
  StremioMeta item,
) async {
  final addon = item.sourceAddon ?? await _metadataAddon();
  if (!context.mounted) return;

  Future<void> unavailable(
    BuildContext routeContext, {
    int? season,
    int? episode,
  }) async {
    if (await DownloadedMediaService.playMatching(
      routeContext,
      item.imdbId ?? item.id,
      season: season,
      episode: episode,
    )) {
      return;
    }
    if (!routeContext.mounted) return;
    ScaffoldMessenger.of(routeContext).showSnackBar(
      SnackBar(
        content: Text('“${item.name}” is not downloaded on this device.'),
      ),
    );
  }

  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (routeContext) => MergedDetailScreen(
        item: item,
        addon: addon,
        onResume: (promised) => unavailable(
          routeContext,
          season: promised?.season,
          episode: promised?.episode,
        ),
        onQuickPlay: (selection) => unavailable(
          routeContext,
          season: selection.season,
          episode: selection.episode,
        ),
        recommendationsLoader: (item.imdbId ?? item.id).startsWith('tt')
            ? () => StremioService.instance.getRecommendations(
                imdbId: item.imdbId ?? item.id,
                type: item.type,
              )
            : null,
        onRecommendationTap: (next) {
          unawaited(_openDownloadedCatalogPreview(routeContext, next));
        },
        metaEnricher: (id, type) =>
            StremioService.instance.fetchMetaDetails(imdbId: id, type: type),
      ),
    ),
  );
}

List<LocalDownload> sortDownloads(Iterable<LocalDownload> items) =>
    [...items]..sort((a, b) {
      final season = (a.media?.season ?? 0).compareTo(b.media?.season ?? 0);
      return season != 0
          ? season
          : (a.media?.episode ?? 0).compareTo(b.media?.episode ?? 0);
    });

/// The look of the Home detail page, resolved the same way it resolves it.
DetailTheme _detailTheme() => ThemeCoreResolver.resolve(
  effectiveDetailTheme(StorageService.detailThemeCached),
  AppThemeController.instance.isLegacy
      ? ThemeOverrides.none
      : AppThemeController.instance.overrides,
  structureId: AppThemeController.instance.formCoreId,
);

/// A title's download page: what's on the device, what's still coming, and
/// the controls to play or remove it — drawn in the Home detail page's theme
/// with its own buttons.
/// Catalog details for a download page: the title's meta and, for a series,
/// its episode list (Stremio `videos`: season, number, title, overview,
/// thumbnail).
typedef DownloadedTitleDetails = ({
  StremioMeta? meta,
  List<Map<String, dynamic>> videos,
});

Future<DownloadedTitleDetails> _loadTitleDetails(LocalDownload first) async {
  final media = first.media;
  if (media == null || !media.isCatalogLinked) {
    return (meta: null, videos: const <Map<String, dynamic>>[]);
  }
  final store = OfflineTitleStore.instance;
  final saved = await store.read(
    media.id,
    '${OfflineTitleStore.meta}:${media.type}',
  );
  final snapshot = PageSnapshot.fromJson(
    await store.read(media.id, OfflineTitleStore.page),
  );
  final savedVideos = await store.read(media.id, OfflineTitleStore.videos);
  return (
    meta:
        snapshot?.meta ??
        (saved is Map
            ? StremioMeta.fromJson(Map<String, dynamic>.from(saved))
            : null),
    videos: savedVideos is List
        ? [
            for (final video in savedVideos)
              if (video is Map) Map<String, dynamic>.from(video),
          ]
        : const <Map<String, dynamic>>[],
  );
}

class DownloadedTitleScreen extends StatefulWidget {
  final List<LocalDownload> items;

  /// Loads the title's details and episode stills. Offline or unlinked
  /// files simply keep the plain file rows.
  @visibleForTesting
  final Future<DownloadedTitleDetails> Function(LocalDownload first)?
  detailsLoader;
  const DownloadedTitleScreen({
    super.key,
    required this.items,
    this.detailsLoader,
  });
  @override
  State<DownloadedTitleScreen> createState() => _DownloadedTitleScreenState();
}

class _DownloadedTitleScreenState extends State<DownloadedTitleScreen> {
  bool _playing = false;
  late List<LocalDownload> _items;
  final Map<String, double> _progress = {};
  StreamSubscription? _statusSub, _moveSub, _progressSub;
  int _revision = 0;
  Future<void> _reload() async {
    final revision = ++_revision;
    try {
      final items = await DownloadedMediaService.load(includeTransfers: true);
      if (!mounted || revision != _revision) return;
      setState(
        () => _items = items.where((e) => e.groupKey == _groupKey).toList(),
      );
      if (_items.isEmpty) Navigator.of(context).pop();
    } catch (_) {}
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _moveSub?.cancel();
    _progressSub?.cancel();
    super.dispose();
  }

  StremioMeta? _meta;
  final Map<String, Map<String, dynamic>> _episodes = {};

  Future<void> _loadDetails() async {
    try {
      final details = await (widget.detailsLoader ?? _loadTitleDetails)(
        _items.first,
      );
      if (!mounted) return;
      setState(() {
        _meta = details.meta;
        for (final video in details.videos) {
          final season = int.tryParse('${video['season']}');
          final number = int.tryParse('${video['number'] ?? video['episode']}');
          if (season != null && number != null) {
            _episodes['$season:$number'] = video;
          }
        }
      });
    } catch (_) {
      /* Details are a bonus; the page works from the files alone. */
    }
  }

  Map<String, dynamic>? _episodeOf(LocalDownload item) {
    final media = item.media;
    if (media?.season == null || media?.episode == null) return null;
    return _episodes['${media!.season}:${media.episode}'];
  }

  @override
  void initState() {
    super.initState();
    _items = [...widget.items];
    _groupKey = widget.items.first.groupKey;
    unawaited(_loadDetails());
    _statusSub = DownloadService.instance.statusStream.listen((_) => _reload());
    _moveSub = DownloadService.instance.moveProgressStream.listen((e) {
      if (e.done || e.failed) _reload();
    });
    _progressSub = DownloadService.instance.progressStream.listen((e) {
      if (!mounted || e.progress < 0) return;
      if (!_items.any((i) => i.record.taskId == e.task.taskId)) return;
      setState(() => _progress[e.task.taskId] = e.progress);
    });
  }

  final Set<String> _retrying = {};

  /// Which library entry this page shows — follows a Fix match to the title
  /// the files were refiled under.
  late String _groupKey;

  /// Fix match from the download page itself: refile every file here under
  /// the title the user picks, then show it as that title.
  Future<void> _fixMatch() async {
    final first = _items.first;
    final picked = await showFixMatchDialog(
      context,
      initialQuery: first.media?.isCatalogLinked == true
          ? first.media!.title
          : _searchableName(first),
    );
    if (picked == null || !mounted) return;
    final type = picked.type == 'series' ? 'series' : 'movie';
    final id = picked.effectiveImdbId ?? picked.id;
    try {
      await DownloadedMediaService.rematch(
        _items,
        id: id,
        title: picked.name,
        type: type,
        poster: picked.poster,
        year: picked.year,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn\'t save the match. Try again.')),
        );
      }
      return;
    }
    if (!mounted) return;
    _groupKey = '$type:$id';
    _episodes.clear();
    _meta = null;
    await _reload();
    if (!mounted || _items.isEmpty) return;
    unawaited(_loadDetails());
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('Filed under ${picked.name}')));
  }

  /// Restarts a failed download — from where it stopped when the platform
  /// kept resume data, otherwise from its saved record.
  Future<void> _retry(LocalDownload item) async {
    final id = item.record.taskId;
    if (!_retrying.add(id)) return;
    setState(() {});
    var ok = false;
    try {
      ok = await DownloadService.instance.resume(item.record.task);
    } catch (_) {}
    if (!mounted) return;
    setState(() => _retrying.remove(id));
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not retry this download. Try again later.'),
        ),
      );
    }
    await _reload();
  }

  Future<void> _remove(LocalDownload item) async {
    final deleteFile = item.isReady && !item.location.startsWith('content://');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          deleteFile || !item.isReady
              ? 'Delete download?'
              : 'Remove from library?',
        ),
        content: Text(
          deleteFile
              ? 'Delete “${item.record.task.filename}” from this device? You can download it again later.'
              : !item.isReady
              ? 'Remove “${item.record.task.filename}” from your downloads? You can download it again later.'
              : 'Remove this entry from the library? The file will remain on your device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(deleteFile ? 'Delete' : 'Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      // Recheck the active profile before touching a file from an open
      // detail route. (A file found in the download folder has no queue
      // record to check; the library already hid other profiles' files.)
      if (!item.isScanned) {
        final owned = await DownloadService.instance.allRecords();
        if (!owned.any((record) => record.taskId == item.record.taskId)) {
          return;
        }
      }
      await DownloadedMediaService.remove(item);
      if (!mounted) return;
      setState(
        () => _items.removeWhere(
          (entry) => entry.record.taskId == item.record.taskId,
        ),
      );
      if (_items.isEmpty) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not remove this download. Try again.'),
          ),
        );
      }
    }
  }

  Future<void> _play(LocalDownload item) async {
    if (_playing) return;
    setState(() => _playing = true);
    try {
      await DownloadedMediaService.play(context, item);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open this download.')),
        );
      }
    } finally {
      if (mounted) setState(() => _playing = false);
    }
  }

  double _progressOf(LocalDownload item) =>
      (_progress[item.record.taskId] ?? item.record.progress)
          .clamp(0, 1)
          .toDouble();

  String _transferStatus(LocalDownload item) => switch (item.record.status) {
    TaskStatus.running => 'Downloading ${(_progressOf(item) * 100).round()}%',
    TaskStatus.paused => 'Paused',
    TaskStatus.failed => 'Download failed',
    TaskStatus.waitingToRetry => 'Retrying',
    _ => 'Queued',
  };

  String? _thumbnailOf(LocalDownload item, bool series, String? fallback) {
    final episode = series ? _episodeOf(item) : null;
    final still = episode?['thumbnail']?.toString();
    return (still != null && still.isNotEmpty) ? still : fallback;
  }

  String _episodeTitle(LocalDownload item) {
    final name = (_episodeOf(item)?['title'] ?? _episodeOf(item)?['name'])
        ?.toString()
        .trim();
    final label = item.media!.episodeLabel;
    return name == null || name.isEmpty ? label : '$label  ·  $name';
  }

  @override
  Widget build(BuildContext context) {
    final items = sortDownloads(_items);
    if (items.isEmpty) return const Scaffold(body: SizedBox.shrink());
    final t = _detailTheme();
    return DetailThemeScope(
      theme: t,
      child: DetailAtmosphere(
        child: LayoutBuilder(
          builder: (context, c) => _body(context, t, items, c.maxWidth),
        ),
      ),
    );
  }

  Widget _body(
    BuildContext context,
    DetailTheme t,
    List<LocalDownload> items,
    double width,
  ) {
    final app = AppThemeScope.of(context);
    final first = items.first;
    final ready = items.where((item) => item.isReady).toList();
    final transfers = items.where((item) => !item.isReady).toList();
    final series = first.media?.type == 'series';
    final gutter = width >= 900 ? 48.0 : 20.0;
    final poster = highQualityArtworkUrl(_meta?.poster ?? first.media?.poster);
    final backdrop = highQualityArtworkUrl(_meta?.background) ?? poster;
    final description = _meta?.description?.trim();
    final facts = [
      ?(_meta?.year ?? first.media?.year),
      if (_meta?.runtime case final runtime? when runtime.isNotEmpty) runtime,
      ...?_meta?.genres?.take(3),
      if (_meta?.imdbRating case final rating?)
        '★ ${rating.toStringAsFixed(1)}',
    ].join('  ·  ');
    final failed = transfers
        .where((e) => e.record.status == TaskStatus.failed)
        .length;
    final eyebrow = ready.isNotEmpty
        ? 'AVAILABLE OFFLINE'
        : failed == transfers.length
        ? 'DOWNLOAD FAILED'
        : 'DOWNLOAD IN PROGRESS';
    final meta = [
      if (series)
        '${ready.length} downloaded ${ready.length == 1 ? 'episode' : 'episodes'}'
      else
        first.media?.year ?? 'Downloaded file',
      if (transfers.length > failed) '${transfers.length - failed} in progress',
      if (failed > 0) '$failed failed',
    ].join('  ·  ');

    return Scaffold(
      backgroundColor: t.ground,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Backdrop: the title's art, faded into the page ground the way the
          // Home detail hero fades into its body.
          if (backdrop != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: width < 600 ? 360 : 520,
              child: ShaderMask(
                shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.white, Colors.transparent],
                ).createShader(rect),
                blendMode: BlendMode.dstIn,
                child: Opacity(
                  opacity: 0.45,
                  child: CachedNetworkImage(
                    imageUrl: backdrop,
                    cacheManager: DebrifyImageCache.manager,
                    fit: BoxFit.cover,
                    alignment: Alignment.topCenter,
                    errorWidget: (_, _, _) => const SizedBox.shrink(),
                  ),
                ),
              ),
            ),
          SafeArea(
            child: ListView(
              padding: EdgeInsets.fromLTRB(gutter, 8, gutter, 40),
              children: [
                Row(
                  children: [
                    Tooltip(
                      message: 'Back',
                      child: DetailRoundButton(
                        icon: Icons.arrow_back_rounded,
                        onTap: () => Navigator.of(context).maybePop(),
                      ),
                    ),
                    const Spacer(),
                    Tooltip(
                      message: 'Fix match',
                      child: DetailRoundButton(
                        icon: Icons.manage_search_rounded,
                        onTap: _fixMatch,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Wrap(
                  spacing: 28,
                  runSpacing: 24,
                  crossAxisAlignment: WrapCrossAlignment.end,
                  children: [
                    SizedBox(
                      width: width < 600 ? 120 : 168,
                      child: AspectRatio(
                        aspectRatio: 2 / 3,
                        child: ClipRRect(
                          borderRadius: app.shape.br(14),
                          child: _Artwork(url: poster, theme: t),
                        ),
                      ),
                    ),
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: (width - gutter * 2).clamp(100, 640),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                ready.isEmpty
                                    ? Icons.downloading_rounded
                                    : Icons.offline_pin_rounded,
                                size: 15,
                                color: t.accent,
                              ),
                              const SizedBox(width: 6),
                              Text(
                                eyebrow,
                                style: TextStyle(
                                  color: t.accent,
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.4,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          Text(
                            first.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: t.tx,
                              fontSize: width < 600 ? 28 : 40,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -0.8,
                              height: 1.08,
                            ),
                          ),
                          const SizedBox(height: 10),
                          if (facts.isNotEmpty) ...[
                            Text(
                              facts,
                              style: TextStyle(
                                color: t.tx2,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                          ],
                          Text(
                            meta,
                            style: TextStyle(
                              color: t.tx3,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (description != null &&
                              description.isNotEmpty) ...[
                            const SizedBox(height: 12),
                            Text(
                              description,
                              maxLines: 4,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: t.tx2,
                                fontSize: 14,
                                height: 1.45,
                              ),
                            ),
                          ],
                          const SizedBox(height: 20),
                          Wrap(
                            spacing: 10,
                            runSpacing: 10,
                            children: [
                              if (ready.isNotEmpty)
                                DetailPrimaryButton(
                                  label: series
                                      ? 'Play ${ready.first.media!.episodeLabel}'
                                      : 'Play',
                                  busy: _playing,
                                  glow: t.accent,
                                  onTap: () => _play(ready.first),
                                ),
                              DetailGhostButton(
                                label: 'Manage downloads',
                                icon: Icons.tune_rounded,
                                onTap: () async {
                                  await openDownloadManager(context);
                                  await _reload();
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (ready.isNotEmpty) ...[
                  const SizedBox(height: 36),
                  _SectionTitle(series ? 'Episodes' : 'Files', theme: t),
                  for (final item in ready)
                    _DownloadRow(
                      theme: t,
                      icon: Icons.play_arrow_rounded,
                      title: series ? _episodeTitle(item) : item.title,
                      overview: _episodeOf(item)?['overview']?.toString(),
                      thumbnail: _thumbnailOf(item, series, backdrop),
                      subtitle: item.record.task.filename,
                      onTap: _playing ? null : () => _play(item),
                      trailing: Tooltip(
                        message: 'Remove download',
                        child: DetailRoundButton(
                          icon: Icons.delete_outline_rounded,
                          size: 36,
                          onTap: () {
                            if (!_playing) _remove(item);
                          },
                        ),
                      ),
                    ),
                ],
                if (transfers.isNotEmpty) ...[
                  const SizedBox(height: 28),
                  _SectionTitle(
                    failed == transfers.length ? 'Failed' : 'Downloading',
                    theme: t,
                  ),
                  for (final item in transfers)
                    _DownloadRow(
                      theme: t,
                      icon: item.record.status == TaskStatus.failed
                          ? Icons.error_outline_rounded
                          : Icons.downloading_rounded,
                      title:
                          series && item.media?.episodeLabel.isNotEmpty == true
                          ? _episodeTitle(item)
                          : item.title,
                      thumbnail: _thumbnailOf(item, series, backdrop),
                      subtitle:
                          '${_transferStatus(item)}  ·  ${item.record.task.filename}',
                      progress: item.record.status == TaskStatus.failed
                          ? null
                          : _progressOf(item),
                      warning: item.record.status == TaskStatus.failed,
                      // Failed: Retry, plus the usual Delete.
                      trailing: item.record.status == TaskStatus.failed
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Tooltip(
                                  message: 'Retry download',
                                  child: DetailRoundButton(
                                    icon: _retrying.contains(item.record.taskId)
                                        ? Icons.hourglass_top_rounded
                                        : Icons.refresh_rounded,
                                    size: 36,
                                    onTap: () => _retry(item),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Tooltip(
                                  message: 'Remove download',
                                  child: DetailRoundButton(
                                    icon: Icons.delete_outline_rounded,
                                    size: 36,
                                    onTap: () => _remove(item),
                                  ),
                                ),
                              ],
                            )
                          : null,
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final DetailTheme theme;
  const _SectionTitle(this.text, {required this.theme});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Text(
      text,
      style: TextStyle(
        color: theme.tx,
        fontSize: 20,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.3,
      ),
    ),
  );
}

/// One file on the download page — the detail page's panel and hairline, with
/// a white progress bar (Home's) while the file is still arriving.
class _DownloadRow extends StatelessWidget {
  final DetailTheme theme;
  final IconData icon;
  final String title, subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;
  final double? progress;

  /// Episode still (or the title's art); the row falls back to an icon disc.
  final String? thumbnail;
  final String? overview;

  /// A failed transfer — its status line reads in the error colour.
  final bool warning;
  const _DownloadRow({
    this.warning = false,
    required this.theme,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.trailing,
    this.progress,
    this.thumbnail,
    this.overview,
  });

  @override
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, c) => _build(context, c.maxWidth));

  Widget _build(BuildContext context, double width) {
    final t = theme;
    final app = AppThemeScope.of(context);
    final radius = app.shape.br(14);
    // Narrow rows put the still on top, full width, like Home's episode cards.
    final stacked = thumbnail != null && width < 520;
    final Widget details = Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: t.tx,
              fontSize: 15,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (overview != null && overview!.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              overview!.trim(),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: t.tx2, fontSize: 13, height: 1.35),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            subtitle,
            maxLines: overview == null ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: warning ? HomeTheme.danger : t.tx3,
              fontSize: 12,
              fontWeight: warning ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          if (progress != null) ...[
            const SizedBox(height: 9),
            ClipRRect(
              borderRadius: app.shape.br(2),
              child: SizedBox(
                height: 3,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: HomeTheme.progressTrack),
                    FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: progress!,
                      child: const DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: HomeTheme.progressGradient,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: t.panel,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
            decoration: BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: t.hair),
            ),
            child: stacked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Still(
                        url: thumbnail!,
                        icon: icon,
                        theme: t,
                        width: double.infinity,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          details,
                          if (trailing != null) ...[
                            const SizedBox(width: 8),
                            trailing!,
                          ],
                        ],
                      ),
                    ],
                  )
                : Row(
                    children: [
                      if (thumbnail != null)
                        _Still(
                          url: thumbnail!,
                          icon: icon,
                          theme: t,
                          width: width < 900 ? 150 : 176,
                        )
                      else
                        Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: t.ghostFill,
                            border: Border.all(color: t.ghostBorder),
                          ),
                          child: Icon(icon, color: t.ghostText, size: 20),
                        ),
                      const SizedBox(width: 14),
                      details,
                      if (trailing != null) ...[
                        const SizedBox(width: 8),
                        trailing!,
                      ],
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

/// A 16:9 episode still with the row's action icon over it.
class _Still extends StatelessWidget {
  final String url;
  final IconData icon;
  final DetailTheme theme;
  final double width;
  const _Still({
    required this.url,
    required this.icon,
    required this.theme,
    required this.width,
  });
  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    return SizedBox(
      width: width,
      child: AspectRatio(
        aspectRatio: 16 / 9,
        child: ClipRRect(
          borderRadius: app.shape.br(10),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: theme.ground),
              CachedNetworkImage(
                imageUrl: url,
                cacheManager: DebrifyImageCache.manager,
                fit: BoxFit.cover,
                errorWidget: (_, _, _) => const SizedBox.shrink(),
              ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Color(0x99000000)],
                  ),
                ),
              ),
              Center(
                child: Container(
                  width: 34,
                  height: 34,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.45),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.6),
                    ),
                  ),
                  child: Icon(icon, color: Colors.white, size: 20),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Artwork extends StatelessWidget {
  final String? url;
  final DetailTheme theme;
  const _Artwork({this.url, required this.theme});
  @override
  Widget build(BuildContext context) {
    final placeholder = ColoredBox(
      color: theme.panel,
      child: Center(
        child: Icon(Icons.movie_outlined, size: 44, color: theme.tx3),
      ),
    );
    return url == null
        ? placeholder
        : CachedNetworkImage(
            imageUrl: url!,
            cacheManager: DebrifyImageCache.manager,
            fit: BoxFit.cover,
            placeholder: (_, _) => placeholder,
            errorWidget: (_, _, _) => placeholder,
          );
  }
}

/// Home's white-on-glass control, as the merged detail page draws it.
class _GlassPillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _GlassPillButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    final radius = app.shape.brPill;
    return Material(
      color: Colors.white.withValues(alpha: 0.08),
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 18),
              const SizedBox(width: 7),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GlassIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _GlassIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Material(
      color: Colors.white.withValues(alpha: 0.08),
      shape: CircleBorder(
        side: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
      ),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox.square(
          dimension: 40,
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    ),
  );
}

/// A file name cut down to something a catalog search can match: no
/// extension, no dots/underscores, and nothing from the first season/episode
/// tag, year or quality marker on.
String _searchableName(LocalDownload item) {
  final media = item.media;
  if (media != null && !media.title.contains('.')) return media.title;
  var name = item.record.task.filename;
  final dot = name.lastIndexOf('.');
  if (dot > 0) name = name.substring(0, dot);
  name = name.replaceAll(RegExp(r'[._]+'), ' ');
  final cut = RegExp(
    r'\b(s\d{1,2}e\d{1,3}|s\d{1,2}|\d{1,2}x\d{1,3}|(19|20)\d{2}|\d{3,4}p|'
    r'web[ -]?dl|webrip|bluray|hdtv|x26[45]|hevc)\b',
    caseSensitive: false,
  ).firstMatch(name);
  if (cut != null && cut.start > 0) name = name.substring(0, cut.start);
  return name.replaceAll(RegExp(r'[\[\(\-]+\s*$'), '').trim();
}

/// Fix match: search the catalogs for the title a download really is.
/// Returns the picked movie or series, or null when dismissed.
@visibleForTesting
Future<StremioMeta?> showFixMatchDialog(
  BuildContext context, {
  required String initialQuery,
  Future<List<StremioMeta>> Function(String query)? search,
}) {
  return showDialog<StremioMeta>(
    context: context,
    builder: (_) => _FixMatchDialog(
      initialQuery: initialQuery,
      search: search ?? StremioService.instance.searchCatalogs,
    ),
  );
}

class _FixMatchDialog extends StatefulWidget {
  final String initialQuery;
  final Future<List<StremioMeta>> Function(String query) search;

  const _FixMatchDialog({required this.initialQuery, required this.search});

  @override
  State<_FixMatchDialog> createState() => _FixMatchDialogState();
}

class _FixMatchDialogState extends State<_FixMatchDialog> {
  late final TextEditingController _query = TextEditingController(
    text: widget.initialQuery,
  );
  List<StremioMeta>? _results;
  bool _searching = false;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    if (widget.initialQuery.trim().isNotEmpty) _run();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    final generation = ++_generation;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final found = await widget.search(query);
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = [
          for (final m in found)
            if (m.type == 'movie' || m.type == 'series') m,
        ];
        _searching = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _searching = false;
        _error = 'Search failed. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = AppThemeScope.of(context);
    final size = MediaQuery.sizeOf(context);
    final results = _results;
    return Dialog(
      backgroundColor: app.sheetSurface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 32),
      shape: RoundedRectangleBorder(borderRadius: app.shape.br(20)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: size.height * 0.8,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Fix match',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'Pick the movie or show these files are.',
                style: TextStyle(
                  color: app.fade(app.core.tx, 0.55),
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _query,
                autofocus: true,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _run(),
                decoration: InputDecoration(
                  hintText: 'Title',
                  prefixIcon: const Icon(Icons.search_rounded),
                  suffixIcon: IconButton(
                    tooltip: 'Search',
                    icon: const Icon(Icons.arrow_forward_rounded),
                    onPressed: _run,
                  ),
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : _error != null || (results != null && results.isEmpty)
                    ? Padding(
                        padding: const EdgeInsets.all(20),
                        child: Text(
                          _error ?? 'No movies or shows found.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: app.fade(app.core.tx, 0.6)),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: results?.length ?? 0,
                        itemBuilder: (context, i) {
                          final m = results![i];
                          final poster = m.poster;
                          return ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 4,
                            ),
                            leading: ClipRRect(
                              borderRadius: app.shape.br(6),
                              child: SizedBox(
                                width: 36,
                                height: 54,
                                child: poster == null || poster.isEmpty
                                    ? ColoredBox(
                                        color: app.fade(app.core.tx, 0.08),
                                        child: const Icon(
                                          Icons.movie_rounded,
                                          size: 18,
                                        ),
                                      )
                                    : CachedNetworkImage(
                                        imageUrl: poster,
                                        fit: BoxFit.cover,
                                        memCacheWidth: 108,
                                        errorWidget: (_, _, _) =>
                                            const SizedBox.shrink(),
                                      ),
                              ),
                            ),
                            title: Text(
                              m.name,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              [
                                m.type == 'series' ? 'Series' : 'Movie',
                                if (m.year != null && m.year!.isNotEmpty)
                                  m.year!,
                              ].join('  ·  '),
                            ),
                            onTap: () => Navigator.of(context).pop(m),
                          );
                        },
                      ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
