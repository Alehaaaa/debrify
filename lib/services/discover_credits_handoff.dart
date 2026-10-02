import 'package:flutter/material.dart';

/// A person's or studio's titles, shown as a fixed-source Discover page.
@immutable
class DiscoverCreditsRequest {
  const DiscoverCreditsRequest({
    required this.kind,
    required this.title,
    this.tmdbId,
    this.imdbId,
    this.type = 'movie',
  });

  /// 'person' or 'company' — the browse kinds Discover already renders.
  final String kind;
  final String title;

  /// TMDB person/company ID, used when this build has TMDB.
  final int? tmdbId;

  /// IMDb `nm…`/`co…` ID, the token-free fallback.
  final String? imdbId;

  /// Initial Type filter ('movie' | 'tv').
  final String type;

  String get key => '$kind:${imdbId ?? tmdbId}';
}

/// Opens a person's or studio's titles as their own Discover page: the same
/// panel as the Discover tab (filters, poster grid, detail rail, trailer
/// stage) with the source fixed — titled with the name instead of a Source
/// dropdown, and a back button instead of the app's navigation.
///
/// The page itself is the Discover screen, registered by the app shell at
/// startup ([pageBuilder]) so this layer never imports the screen.
abstract final class DiscoverCreditsHandoff {
  static Widget Function(DiscoverCreditsRequest request, bool isTelevision)?
  pageBuilder;

  /// False when no page is registered (the caller falls back to its own).
  static bool open(
    BuildContext context,
    DiscoverCreditsRequest request, {
    required bool isTelevision,
  }) {
    final builder = pageBuilder;
    if (builder == null) return false;
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => builder(request, isTelevision)),
    );
    return true;
  }
}
