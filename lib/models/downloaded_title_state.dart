import 'package:flutter/material.dart';

/// Where a catalog title stands on this device.
enum DownloadedTitleState { none, downloading, downloaded }

extension DownloadedTitleStateLabel on DownloadedTitleState {
  String get label => switch (this) {
    DownloadedTitleState.none => 'Download',
    DownloadedTitleState.downloading => 'Downloading',
    DownloadedTitleState.downloaded => 'Downloaded',
  };

  IconData get icon => switch (this) {
    DownloadedTitleState.none => Icons.download_rounded,
    DownloadedTitleState.downloading => Icons.downloading_rounded,
    DownloadedTitleState.downloaded => Icons.offline_pin_rounded,
  };
}
