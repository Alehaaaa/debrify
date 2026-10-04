import 'dart:async';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import 'offline_title_store.dart';

/// Shared image disk cache for poster/thumbnail-heavy surfaces.
///
/// `CachedNetworkImage` without an explicit manager uses `DefaultCacheManager`,
/// which caps the store at 200 objects (LRU). A single TV browsing session —
/// Home rows, Discover boards, backdrops — churns straight through that, so by
/// the time a series page is reopened its episode stills have been evicted and
/// every one re-downloads. Pass this manager as `cacheManager:` at image-heavy
/// call sites so artwork survives a browsing session.
///
/// Note: images cached here live under their own cache key, separate from the
/// default manager's store — a URL cached by one is not visible to the other.
class DebrifyImageCache {
  DebrifyImageCache._();

  /// Reclaim legacy orphan files and enforce budgets even if the user does
  /// not visit the surfaces that used these stores in the previous session.
  static Future<void> maintainDiskCaches() async {
    await Future.wait(
      [() => DefaultCacheManager(), () => manager, () => iptvLogos].map((
        open,
      ) async {
        try {
          await open().store.cleanCache();
        } catch (_) {
          // Best effort. The normal cache access/write path retries maintenance.
        }
      }),
    );
  }

  /// Also serves the artwork saved for downloaded titles
  /// ([OfflineTitleStore]), so their detail pages keep their images offline
  /// and after this cache has evicted them.
  static final CacheManager manager = _OfflineAwareCacheManager(
    Config(
      'debrifyImageCache',
      // Count and byte limits apply together; large backdrops cannot consume
      // an unbounded amount of storage just because there are few of them.
      maxNrOfCacheObjects: 1000,
      maxCacheSizeBytes: 256 * 1024 * 1024,
      stalePeriod: const Duration(days: 30),
    ),
  );

  /// Separate store for IPTV channel logos: tiny files, huge cardinality.
  /// They used to ride the DEFAULT manager's 200-object store, so scrolling
  /// a big guide re-downloaded every logo continuously; and sharing
  /// [manager] instead would let one 50k-channel scroll evict every Home
  /// backdrop and poster. A dedicated store keeps each surface's churn to
  /// itself — 2000 logos at the typical 10-50 KB is tens of MB of disk, cap.
  static final CacheManager iptvLogos = CacheManager(
    Config(
      'debrifyIptvLogoCache',
      maxNrOfCacheObjects: 2000,
      maxCacheSizeBytes: 32 * 1024 * 1024,
      stalePeriod: const Duration(days: 30),
    ),
  );
}

/// [CacheManager] that answers from a downloaded title's saved artwork first,
/// and saves what a downloaded title's detail page loads while it is open.
class _OfflineAwareCacheManager extends CacheManager {
  _OfflineAwareCacheManager(super.config);

  static const _pinnedAge = Duration(days: 3650);

  @override
  Stream<FileResponse> getFileStream(
    String url, {
    String? key,
    Map<String, String>? headers,
    bool withProgress = false,
  }) async* {
    final store = OfflineTitleStore.instance;
    final saved = await store.imageFile(url);
    if (saved != null) {
      final cacheKey = key ?? url;
      FileInfo? cached;
      try {
        cached = await getFileFromCache(cacheKey);
        if (cached != null && !await cached.file.exists()) cached = null;
        if (cached == null) {
          final file = await putFile(
            url,
            await saved.readAsBytes(),
            key: cacheKey,
            maxAge: _pinnedAge,
            fileExtension: saved.path.split('.').last,
          );
          cached = FileInfo(
            file,
            FileSource.Cache,
            DateTime.now().add(_pinnedAge),
            url,
          );
        }
      } catch (_) {
        cached = null;
      }
      if (cached != null) {
        // Saved art is served as-is: no revalidation, so no network needed.
        yield cached;
        return;
      }
    }
    final owner = store.activeImageOwner;
    await for (final response in super.getFileStream(
      url,
      key: key,
      headers: headers,
      withProgress: withProgress,
    )) {
      if (owner != null && response is FileInfo) {
        unawaited(store.pinImage(owner, url, source: response.file.path));
      }
      yield response;
    }
  }
}
