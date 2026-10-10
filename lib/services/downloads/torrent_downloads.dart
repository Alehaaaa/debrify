part of '../torrent_playback_service.dart';

/// Getting a title onto the device from a source: the pack file picker, the
/// Download button's automatic pick, direct-stream downloads and "download
/// when ready" for torrents the debrid service is still fetching. Shares the
/// library with [TorrentPlaybackService] for its provider resolution.
abstract final class TorrentDownloads {
  /// Native media-server streams need credential-aware background downloads,
  /// including redirect and resource-revocation handling, before enabling this.
  static bool supportsDirectStreamDownload(Torrent torrent) =>
      !MediaServerService.owns(torrent);

  /// Download a direct/external addon stream to device (parity with the old
  /// screen's direct-stream "Download to device" action). Follows redirects
  /// first — MediaFusion-style playback URLs 30x-hop to the real file — then
  /// queues the resolved URL.
  static Future<void> downloadDirectStream(
    BuildContext context,
    Torrent torrent, {
    PlaybackMeta? meta,
  }) async {
    if (!supportsDirectStreamDownload(torrent)) {
      if (context.mounted) {
        DownloadFeedback.info(
          context,
          'Jellyfin and Emby downloads are not supported yet.',
        );
      }
      return;
    }
    if (IptvSourceSearch.isDeferredXtreamSeries(torrent)) {
      if (context.mounted) {
        DownloadFeedback.info(context, 'Finding this IPTV episode…');
      }
      final resolution = await IptvSourceSearch.resolveXtreamSeriesEpisode(
        torrent,
      );
      if (!context.mounted) return;
      if (resolution.source == null) {
        DownloadFeedback.info(
          context,
          resolution.status == IptvEpisodeResolutionStatus.missing
              ? '${torrent.episodeIdentifier ?? 'This episode'} is not available in this IPTV series.'
              : 'Could not check this IPTV series. Try again.',
        );
        return;
      }
      torrent = resolution.source!;
    }
    try {
      await DirectSourceAuthorization.authorize(torrent);
    } catch (_) {
      if (context.mounted) {
        DownloadFeedback.info(
          context,
          'IPTV connection changed. Search sources again.',
        );
      }
      return;
    }
    if (!context.mounted) return;
    final raw = torrent.directUrl ?? '';
    if (raw.isEmpty) {
      DownloadFeedback.info(context, 'No stream URL available.');
      return;
    }
    DownloadFeedback.info(context, 'Preparing the download…');
    final resolved = await _resolveDownloadUrl(raw);
    try {
      await DirectSourceAuthorization.authorize(torrent);
      await DownloadService.instance.enqueueDownload(
        url: resolved,
        fileName: torrent.displayTitle,
        meta: downloadMediaMetadata(meta, fileName: torrent.displayTitle),
        torrentName: torrent.displayTitle,
      );
      if (context.mounted) {
        DownloadFeedback.started(context, titleId: _titleId(meta));
      }
    } catch (_) {
      if (context.mounted) {
        DownloadFeedback.failed(context);
      }
    }
  }

  /// Follow up to 10 redirects (HEAD, no auto-follow) to resolve a stream URL to
  /// its final downloadable location, handling relative Location headers. Ported
  /// from the old screen's `_resolveDownloadUrl`.
  static Future<String> _resolveDownloadUrl(String url) async {
    var currentUrl = url;
    var redirectCount = 0;
    while (redirectCount < 10) {
      try {
        final uri = Uri.parse(currentUrl);
        final client = http.Client();
        try {
          final request = http.Request('HEAD', uri);
          request.followRedirects = false;
          request.headers['User-Agent'] =
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36';
          final response = await client
              .send(request)
              .timeout(const Duration(seconds: 10));
          if (response.statusCode == 301 ||
              response.statusCode == 302 ||
              response.statusCode == 303 ||
              response.statusCode == 307 ||
              response.statusCode == 308) {
            final location = response.headers['location'];
            if (location != null && location.isNotEmpty) {
              currentUrl = uri.resolve(location).toString();
              redirectCount++;
              continue;
            }
          }
          return currentUrl; // no redirect → final URL
        } finally {
          client.close();
        }
      } catch (_) {
        break;
      }
    }
    return currentUrl; // best effort (possibly partially resolved)
  }

  /// Resolve a playlist entry to a concrete download URL, unlocking a lazy
  /// debrid entry on demand: RD `restrictedLink` → unrestrict, TorBox
  /// torrent+file id → download link, AllDebrid locked link → unlock. Premiumize
  /// entries already carry a URL. Returns null if it can't be resolved.
  static Future<String?> _resolveEntryUrl(PlaylistEntry e) async {
    if (e.url.isNotEmpty) return e.url;
    try {
      if (e.restrictedLink != null && e.restrictedLink!.isNotEmpty) {
        final key = (await StorageService.getApiKey()) ?? '';
        final r = await DebridService.unrestrictLink(key, e.restrictedLink!);
        return r['download']?.toString();
      }
      if (e.torboxTorrentId != null && e.torboxFileId != null) {
        final key = (await StorageService.getTorboxApiKey()) ?? '';
        return await TorboxService.requestFileDownloadLink(
          apiKey: key,
          torrentId: e.torboxTorrentId!,
          fileId: e.torboxFileId!,
        );
      }
      if (e.allDebridLink != null && e.allDebridLink!.isNotEmpty) {
        final key = (await StorageService.getAllDebridApiKey()) ?? '';
        return await AllDebridService.unlockLink(key, e.allDebridLink!);
      }
    } catch (_) {}
    return null;
  }

  /// Multi-select download picker (parity with the old per-file download
  /// dialog): lists the pack's files with sizes, defaults all selected, shows a
  /// running total, and returns the chosen entries — or null if cancelled.
  static Future<List<PlaylistEntry>?> _showDownloadPicker(
    BuildContext context,
    List<PlaylistEntry> entries, {
    Set<int>? preselected,
    Set<int> onDevice = const {},
  }) {
    return showDialog<List<PlaylistEntry>>(
      context: context,
      builder: (dialogCtx) {
        final scheme = Theme.of(dialogCtx).colorScheme;
        // Default: what's worth downloading (no extras, nothing already here).
        final selected = preselected == null
            ? {...entries}
            : {for (final i in preselected) entries[i]};
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            final totalBytes = selected.fold<int>(
              0,
              (sum, e) => sum + (e.sizeBytes ?? 0),
            );
            final allOn = selected.length == entries.length;
            return AlertDialog(
              title: const Text('Download files'),
              content: SizedBox(
                width: double.maxFinite,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => setLocal(() {
                          if (allOn) {
                            selected.clear();
                          } else {
                            selected
                              ..clear()
                              ..addAll(entries);
                          }
                        }),
                        child: Text(allOn ? 'None' : 'All'),
                      ),
                    ),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final (i, e) in entries.indexed)
                            CheckboxListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              controlAffinity: ListTileControlAffinity.leading,
                              value: selected.contains(e),
                              title: Text(
                                e.title,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: scheme.onSurface,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                              subtitle: onDevice.contains(i)
                                  ? Text(
                                      'Already on this device',
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        color: scheme.primary,
                                      ),
                                    )
                                  : null,
                              secondary: Text(
                                (e.sizeBytes ?? 0) > 0
                                    ? Formatters.formatFileSize(e.sizeBytes!)
                                    : '',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              onChanged: (_) => setLocal(() {
                                if (selected.contains(e)) {
                                  selected.remove(e);
                                } else {
                                  selected.add(e);
                                }
                              }),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogCtx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () => Navigator.of(
                          dialogCtx,
                        ).pop(entries.where(selected.contains).toList()),
                  child: Text(
                    totalBytes > 0
                        ? 'Download · ${Formatters.formatFileSize(totalBytes)}'
                        : 'Download',
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// The Download button's automatic path: search the title's sources, keep
  /// the ones matching the user's saved source filters, and download the best
  /// that resolves — the title, or the episodes [scope] covers (a pack that
  /// has several of them covers them at once; a season without an episode
  /// searches its packs).
  ///
  /// When it can't, the outcome says why so the caller can open the source
  /// list with that explanation.
  static Future<DownloadOutcome> downloadBest(
    BuildContext context, {
    required DownloadRequest request,
    DownloadScope? scope,
    required PlaybackMeta meta,
  }) async {
    final imdbId = request.id;
    final isMovie = !request.isSeries;
    final season = request.season;
    final episode = request.searchEpisode(scope);
    final count = request.episodeCount(scope);
    const done = DownloadOutcome.started();
    final label = meta.title ?? '';
    if (!ProfilePolicyGuard.allowsSync(ProfileFeature.downloads)) {
      DownloadFeedback.info(
        context,
        'Downloads are turned off for this profile.',
      );
      return done;
    }
    if (!imdbId.startsWith('tt') || (!isMovie && season == null)) {
      return const DownloadOutcome.missed(DownloadMiss.nothingFound);
    }
    final provider = await TorrentPlaybackService._pickProvider(context);
    if (!context.mounted || provider == TorrentPlaybackService._cancelled) {
      return done;
    }
    if (provider == null) {
      DownloadFeedback.info(
        context,
        'Add a debrid service in Settings to download.',
      );
      return done;
    }
    // In the background: a quiet note with Cancel, never a full-screen
    // loader — the user keeps browsing (or watching) while this runs, and it
    // finishes even if they leave the page that started it.
    var cancelled = false;
    final working = DownloadFeedback.working(
      context,
      label.isEmpty ? 'Finding a source…' : 'Finding a source for $label…',
      onCancel: () => cancelled = true,
    );
    var workingUp = true;
    void closeOverlay() {
      if (!workingUp) return;
      workingUp = false;
      working?.close();
    }

    BuildContext? live() => context.mounted ? context : appContext;

    // The title shows on the Downloads page from here on — poster plus the
    // phase — until a real download task takes over (or the search ends).
    final pending = PendingTitleDownloads.begin(
      PendingTitleDownload(
        id: imdbId,
        title: label.isEmpty ? request.title : label,
        type: isMovie ? 'movie' : 'series',
        poster: meta.posterUrl,
        year: meta.year,
        phase: PendingDownloadPhase.searching,
        onCancel: () {
          cancelled = true;
          closeOverlay();
        },
      ),
    );
    void phase(PendingDownloadPhase value) =>
        PendingTitleDownloads.update(pending, imdbId, value);

    try {
      final rules = await StorageService.getQuickPlayRules(isMovie: isMovie);
      var filters = await SavedSourceFilters.load();
      // Pack sizes are per-episode, so the size facet is movie-only.
      if (!isMovie) filters = filters.copyWith(sizes: const <SizeBucket>{});
      final summary = FilterLadder(filters).filterSummary();

      // One search + resolve + download. Null on success, else why not.
      Future<DownloadMiss?> one({
        int? ep,
        Set<int>? wanted,
        required PlaybackMeta itemMeta,
      }) async {
        phase(PendingDownloadPhase.searching);
        final List<Torrent> found;
        if (isMovie || ep != null) {
          found = await TorrentPlaybackService.searchCuratedSources(
            imdbId: imdbId,
            label: label,
            year: meta.year,
            isMovie: isMovie,
            season: season,
            episode: ep,
            provider: provider,
            rules: rules,
            originMeta: itemMeta,
            isCancelled: () => cancelled,
          );
        } else {
          found =
              await TorrentPlaybackService.searchSeriesPackSources(
                imdbId: imdbId,
                label: label,
                season: season!,
                provider: provider,
                ladder: FilterLadder(filters),
                rules: rules,
                isCancelled: () => cancelled,
              ) ??
              const <Torrent>[];
        }
        if (cancelled || live() == null) return null;
        if (found.isEmpty) return DownloadMiss.nothingFound;
        final matching = TorrentFilterMatcher.apply(found, filters);
        if (matching.isEmpty) return DownloadMiss.noFilterMatch;
        final torrents = TorrentPlaybackService.orderCandidatesForRules(
          matching.where((t) => t.streamType == StreamType.torrent).toList(),
          rules: rules,
        );
        if (torrents.isNotEmpty) {
          phase(PendingDownloadPhase.checking);
          final (
            resolved,
            winner,
          ) = await TorrentPlaybackService._probeCandidates(
            provider,
            torrents,
            season: ep == null ? null : season,
            episode: ep,
            rules: rules,
            isCancelled: () => cancelled,
            // A download is worth a few probes; PikPak still stops at one.
            minAttempts: 3,
          );
          if (cancelled) return null;
          final target = live();
          if (target == null) return null;
          if (resolved != null && winner != null) {
            closeOverlay();
            phase(PendingDownloadPhase.adding);
            await _download(
              target,
              resolved,
              winner,
              provider,
              meta: itemMeta,
              pickFiles: false,
              wantedEpisodes: wanted,
            );
            return null;
          }
        }
        final direct = matching.where(
          (t) =>
              (t.streamType == StreamType.directUrl ||
                  t.streamType == StreamType.externalUrl) &&
              (t.directUrl?.isNotEmpty ?? false) &&
              supportsDirectStreamDownload(t),
        );
        final target = live();
        if (direct.isNotEmpty && target != null) {
          closeOverlay();
          phase(PendingDownloadPhase.adding);
          await downloadDirectStream(target, direct.first, meta: itemMeta);
          return null;
        }
        return DownloadMiss.notReady;
      }

      if (isMovie || episode == null) {
        final miss = await one(itemMeta: meta);
        closeOverlay();
        return miss == null
            ? done
            : DownloadOutcome.missed(miss, filterSummary: summary);
      }

      // Episodes: the first search usually finds a pack that has several;
      // only the ones still missing afterwards get their own search.
      final wanted = {for (var i = 0; i < count; i++) episode + i};
      DownloadMiss? firstMiss;
      var downloadedAny = false;
      for (final ep in wanted.toList()..sort()) {
        if (cancelled || live() == null) break;
        final here = await _episodesOnDevice(meta);
        if (here.contains((season: season!, episode: ep))) continue;
        final remaining = {
          for (final w in wanted)
            if (w >= ep && !here.contains((season: season, episode: w))) w,
        };
        final miss = await one(
          ep: ep,
          wanted: remaining,
          itemMeta: PlaybackMeta(
            imdbId: meta.imdbId,
            contentType: meta.contentType,
            title: meta.title,
            posterUrl: meta.posterUrl,
            year: meta.year,
            catalogItem: meta.catalogItem,
            season: season,
            episode: ep,
          ),
        );
        if (miss == null) {
          downloadedAny = true;
        } else {
          firstMiss ??= miss;
          // Later episodes rarely fare better once the first had nothing.
          if (!downloadedAny) break;
        }
      }
      closeOverlay();
      if (downloadedAny || firstMiss == null) return done;
      return DownloadOutcome.missed(firstMiss, filterSummary: summary);
    } catch (e) {
      closeOverlay();
      if (cancelled) return done;
      final target = live();
      if (target != null) {
        DownloadFeedback.info(
          target,
          'The search didn\'t work this time. Try again.',
        );
      }
      return done;
    } finally {
      closeOverlay();
      PendingTitleDownloads.end(pending, imdbId);
    }
  }

  static Future<void> _download(
    BuildContext context,
    _Resolved r,
    Torrent torrent,
    String provider, {
    PlaybackMeta? meta,
    // Off for auto-download: a pack queues its default files without asking.
    bool pickFiles = true,
    Set<int>? wantedEpisodes,
  }) async {
    final credentialKey = TorrentPlaybackService._credentialKeyForProvider(
      provider,
    );
    // Multi-file pack: let the user choose which files (parity with the old
    // per-file download dialog), then queue each — unlocking lazy debrid entries
    // on demand (RD/TorBox/AllDebrid resolve only the start file up front;
    // Premiumize resolves all).
    if (r.playlist != null && r.playlist!.length > 1) {
      final entries = r.playlist!;
      final onDevice = await _episodesOnDevice(meta);
      final files = <PackFile>[
        for (final e in entries)
          (name: e.relativePath ?? e.title, sizeBytes: e.sizeBytes),
      ];
      final defaults = defaultPackSelection(
        files,
        onDevice: onDevice,
        wanted: wantedEpisodes,
        season: wantedEpisodes == null ? null : meta?.season,
        packName: torrent.displayTitle,
      );
      final here = <int>{
        for (final (i, f) in files.indexed)
          if (detectDownloadedEpisode(f.name, packName: torrent.displayTitle)
              case (season: final int s, episode: final int e)
              when onDevice.contains((season: s, episode: e)))
            i,
      };
      if (!context.mounted) return;
      if (!pickFiles && defaults.isEmpty) {
        DownloadFeedback.info(
          context,
          here.isNotEmpty
              ? 'Those episodes are already on this device.'
              : 'Nothing in this source matches what you asked for.',
        );
        return;
      }
      final chosen = pickFiles
          ? await _showDownloadPicker(
              context,
              entries,
              preselected: defaults,
              onDevice: here,
            )
          : [for (final i in defaults) entries[i]];
      if (chosen == null || chosen.isEmpty) return; // cancelled
      var n = 0;
      for (final e in chosen) {
        final url = await _resolveEntryUrl(e);
        if (url == null || url.isEmpty) continue;
        try {
          await DownloadService.instance.enqueueDownload(
            credentialKey: credentialKey,
            url: url,
            fileName: e.title,
            meta: downloadMediaMetadata(
              meta,
              fileName: e.relativePath ?? e.title,
              isPack: true,
              packName: torrent.displayTitle,
            ),
            torrentName: torrent.displayTitle,
          );
          n++;
        } catch (_) {}
      }
      if (context.mounted) {
        if (n > 0) {
          DownloadFeedback.started(context, titleId: _titleId(meta), files: n);
        } else {
          DownloadFeedback.failed(context);
        }
      }
      return;
    }
    if (r.playlist != null && r.playlist!.isNotEmpty) {
      // Single-entry playlist: queue it directly (no picker for one file).
      final url = await _resolveEntryUrl(r.playlist!.first);
      var queued = false;
      if (url != null && url.isNotEmpty) {
        try {
          await DownloadService.instance.enqueueDownload(
            credentialKey: credentialKey,
            url: url,
            fileName: r.playlist!.first.title,
            meta: downloadMediaMetadata(
              meta,
              fileName: r.playlist!.first.title,
            ),
            torrentName: torrent.displayTitle,
          );
          queued = true;
        } catch (_) {}
      }
      if (context.mounted) {
        if (queued) {
          DownloadFeedback.started(context, titleId: _titleId(meta));
        } else {
          DownloadFeedback.failed(context);
        }
      }
      return;
    }
    final url = r.downloadUrls.isNotEmpty ? r.downloadUrls.first : null;
    if (url == null) {
      DownloadFeedback.info(context, 'Nothing to download for this source.');
      return;
    }
    try {
      await DownloadService.instance.enqueueDownload(
        credentialKey: credentialKey,
        url: url,
        fileName: r.fileName ?? torrent.displayTitle,
        meta: downloadMediaMetadata(
          meta,
          fileName: r.fileName ?? torrent.displayTitle,
        ),
        torrentName: torrent.displayTitle,
      );
    } catch (_) {
      if (context.mounted) {
        DownloadFeedback.failed(context);
      }
      return;
    }
    if (context.mounted) {
      DownloadFeedback.started(context, titleId: _titleId(meta));
    }
  }

  /// Episodes of [meta]'s title already downloaded or downloading here.
  static Future<Set<({int season, int episode})>> _episodesOnDevice(
    PlaybackMeta? meta,
  ) async {
    final id = meta?.imdbId ?? meta?.catalogItem?.id;
    if (id == null || meta?.contentType != 'series') return const {};
    try {
      final all = await DownloadedMediaService.load(includeTransfers: true);
      return {
        for (final d in all)
          if (d.media?.id == id &&
              d.media?.season != null &&
              d.media?.episode != null)
            (season: d.media!.season!, episode: d.media!.episode!),
      };
    } catch (_) {
      return const {};
    }
  }

  // ── Download when ready ────────────────────────────────────────────────────
  //
  // A download picked from a torrent the debrid provider doesn't have yet:
  // instead of an error, offer to let the provider fetch it and start the
  // download on its own once it's ready. Jobs persist (per profile) and are
  // re-checked every minute while the app runs, for up to two days.

  static GlobalKey<NavigatorState>? _navigatorKey;

  /// The app's root context, for work that outlives the page that started it.
  static BuildContext? get appContext {
    final context = _navigatorKey?.currentContext;
    return context != null && context.mounted ? context : null;
  }
  static Timer? _readyTimer;
  static bool _checkingReady = false;
  static const Duration _readyInterval = Duration(minutes: 1);
  static const Duration _readyGiveUp = Duration(hours: 48);

  /// Called once at startup with the app's navigator: resumes waiting jobs.
  static void resumeDownloadsWhenReady(GlobalKey<NavigatorState> key) {
    _navigatorKey = key;
    unawaited(_scheduleReadyChecks());
  }

  static Future<void> _offerDownloadWhenReady(
    BuildContext context,
    Object marker,
    String provider,
    String magnet,
    Torrent torrent, {
    PlaybackMeta? meta,
    Set<int>? wantedEpisodes,
  }) async {
    final label = TorrentPlaybackService._label(provider);
    final wait = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.hourglass_top_rounded),
        title: const Text('Not ready yet'),
        content: Text(
          '$label doesn\'t have this one ready. It can fetch it first — '
          'usually a few minutes — and the download will start on its own '
          'when it\'s done.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Pick another'),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Download when ready'),
          ),
        ],
      ),
    );
    if (wait != true) {
      // Leave nothing behind on the account for a source the user declined.
      await TorrentPlaybackService.cleanupFailedAutomaticAcquisition(marker);
      return;
    }
    try {
      if (provider == 'torbox') {
        final apiKey = (await StorageService.getTorboxApiKey()) ?? '';
        await TorboxService.createTorrent(
          apiKey: apiKey,
          magnet: magnet,
          addOnlyIfCached: false,
        );
      } else if (provider == 'premiumize') {
        final apiKey = (await StorageService.getPremiumizeApiKey()) ?? '';
        await PremiumizeService.createTransfer(apiKey, magnet);
      }
    } catch (_) {
      if (context.mounted) {
        DownloadFeedback.info(
          context,
          'Could not reach $label. Try again in a moment.',
        );
      }
      return;
    }
    await _addReadyJob({
      'provider': provider,
      'magnet': magnet,
      'torrent': torrent.toJson(),
      if (marker is TorrentNotCachedException) 'rdTorrentId': marker.torrentId,
      if (wantedEpisodes != null) 'wanted': wantedEpisodes.toList(),
      'meta': {
        'id': meta?.imdbId ?? meta?.catalogItem?.id,
        'type': meta?.contentType,
        'title': meta?.title ?? meta?.catalogItem?.name,
        'poster': meta?.posterUrl,
        'year': meta?.year,
        'season': meta?.season,
        'episode': meta?.episode,
      },
      'addedAt': DateTime.now().toIso8601String(),
    });
    if (context.mounted) {
      DownloadFeedback.info(
        context,
        'Got it — the download starts as soon as $label has it ready.',
      );
    }
  }

  static Future<List<Map<String, dynamic>>> _readyJobs() async {
    try {
      final raw = await StorageService.getPendingDebridDownloads();
      if (raw == null) return [];
      return [
        for (final job in jsonDecode(raw) as List)
          Map<String, dynamic>.from(job as Map),
      ];
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveReadyJobs(List<Map<String, dynamic>> jobs) =>
      StorageService.setPendingDebridDownloads(
        jobs.isEmpty ? null : jsonEncode(jobs),
      );

  static Future<void> _addReadyJob(Map<String, dynamic> job) async {
    final jobs = await _readyJobs()
      ..removeWhere((j) => j['magnet'] == job['magnet']);
    jobs.add(job);
    await _saveReadyJobs(jobs);
    await _scheduleReadyChecks();
  }

  static Future<void> _scheduleReadyChecks() async {
    final jobs = await _readyJobs();
    if (jobs.isEmpty) {
      _readyTimer?.cancel();
      _readyTimer = null;
      return;
    }
    _readyTimer ??= Timer.periodic(
      _readyInterval,
      (_) => unawaited(_checkReadyJobs()),
    );
  }

  static Future<void> _checkReadyJobs() async {
    if (_checkingReady) return;
    _checkingReady = true;
    try {
      final jobs = await _readyJobs();
      final keep = <Map<String, dynamic>>[];
      for (final job in jobs) {
        final outcome = await _tryReadyJob(job);
        if (outcome == null) keep.add(job);
      }
      await _saveReadyJobs(keep);
      if (keep.isEmpty) {
        _readyTimer?.cancel();
        _readyTimer = null;
      }
    } finally {
      _checkingReady = false;
    }
  }

  /// null = still waiting; true = downloading now; false = given up.
  static Future<bool?> _tryReadyJob(Map<String, dynamic> job) async {
    final provider = job['provider'] as String? ?? '';
    final magnet = job['magnet'] as String? ?? '';
    final title = (job['meta'] as Map?)?['title'] as String?;
    final added = DateTime.tryParse(job['addedAt'] as String? ?? '');
    if (added != null && DateTime.now().difference(added) > _readyGiveUp) {
      _notifyReady(
        '${title ?? 'A download'} took too long on '
        '${TorrentPlaybackService._label(provider)} and was cancelled.',
      );
      return false;
    }
    final Torrent torrent;
    try {
      torrent = Torrent.fromJson(
        Map<String, dynamic>.from(job['torrent'] as Map),
      );
    } catch (_) {
      return false;
    }
    final rdId = job['rdTorrentId'] as String?;
    if (provider == 'debrid' && rdId != null) {
      // Re-adding on RD makes a new entry each time, so ask about the one
      // already fetching instead.
      try {
        final apiKey = (await StorageService.getApiKey()) ?? '';
        final info = await DebridService.getTorrentInfo(apiKey, rdId);
        final status = info['status']?.toString() ?? '';
        if (const {'magnet_error', 'error', 'virus', 'dead'}.contains(status)) {
          _notifyReady('${title ?? 'A download'} failed on Real-Debrid.');
          return false;
        }
        if (status != 'downloaded') return null;
      } catch (_) {
        return null;
      }
    }
    _Resolved resolved;
    try {
      resolved = await TorrentPlaybackService._add(provider, magnet, torrent);
    } on TorrentNotCachedException catch (e) {
      // Only reachable without a tracked RD id; drop the duplicate it made.
      if (e.torrentId != rdId) {
        await TorrentPlaybackService.cleanupFailedAutomaticAcquisition(e);
      }
      return null;
    } on AllDebridTorrentNotReadyException {
      return null;
    } on _TorboxNotCached {
      return null;
    } on _PremiumizeNotCached {
      return null;
    } catch (_) {
      return null;
    }
    if (provider == 'debrid' &&
        rdId != null &&
        resolved.rdTorrentId != null &&
        resolved.rdTorrentId != rdId) {
      // The ready copy resolved; the one we waited on is now a duplicate.
      try {
        final apiKey = (await StorageService.getApiKey()) ?? '';
        await DebridService.deleteTorrent(apiKey, rdId);
      } catch (_) {}
    }
    final context = _navigatorKey?.currentContext;
    if (context == null || !context.mounted) return null;
    final m = Map<String, dynamic>.from(job['meta'] as Map? ?? const {});
    final meta = PlaybackMeta(
      imdbId: m['id'] as String?,
      contentType: m['type'] as String?,
      title: m['title'] as String?,
      posterUrl: m['poster'] as String?,
      year: m['year'] as String?,
      season: (m['season'] as num?)?.toInt(),
      episode: (m['episode'] as num?)?.toInt(),
    );
    final wanted = (job['wanted'] as List?)
        ?.map((e) => (e as num).toInt())
        .toSet();
    await _download(
      context,
      resolved,
      torrent,
      provider,
      meta: meta,
      pickFiles: false,
      wantedEpisodes: wanted,
    );
    return true;
  }

  static void _notifyReady(String message) {
    final context = _navigatorKey?.currentContext;
    if (context != null && context.mounted) {
      DownloadFeedback.info(context, message);
    }
  }

  static String? _titleId(PlaybackMeta? meta) =>
      meta?.imdbId ?? meta?.catalogItem?.id;
}
