import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../services/download_service.dart';
import '../services/downloaded_media_service.dart';
import '../models/downloaded_title_state.dart';
import '../screens/downloads_screen.dart';
export '../models/downloaded_title_state.dart';

/// Live view of the local downloads (finished and in flight) linked to one
/// catalog title. Detail pages use it to turn their source-browse button into
/// a Download button that opens the title's download page once one exists.
class DownloadedTitleWatcher extends ChangeNotifier {
  DownloadedTitleWatcher(this._id) {
    _status = DownloadService.instance.statusStream.listen((_) => _load());
    _moves = DownloadService.instance.moveProgressStream.listen((e) {
      if (e.done || e.failed) _load();
    });
    _load();
  }

  String _id;
  StreamSubscription? _status, _moves;
  List<LocalDownload> _items = const [];
  int _generation = 0;
  bool _disposed = false;

  List<LocalDownload> get items => _items;

  DownloadedTitleState get state => _items.isEmpty
      ? DownloadedTitleState.none
      : _items.any((e) => e.isReady)
      ? DownloadedTitleState.downloaded
      : DownloadedTitleState.downloading;

  set id(String value) {
    if (value == _id) return;
    _id = value;
    _items = const [];
    notifyListeners();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final id = _id;
    try {
      final all = await DownloadedMediaService.load(includeTransfers: true);
      if (_disposed || generation != _generation) return;
      final next = all.where((e) => e.media?.id == id).toList();
      if (listEquals(
        next.map((e) => '${e.record.taskId}:${e.isReady}').toList(),
        _items.map((e) => '${e.record.taskId}:${e.isReady}').toList(),
      )) {
        return;
      }
      _items = next;
      notifyListeners();
    } catch (_) {
      /* Downloads must not prevent browsing catalog details. */
    }
  }

  /// Opens the download page for this title.
  Future<void> open(BuildContext context) async {
    if (_items.isEmpty) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DownloadedTitleScreen(items: _items),
      ),
    );
    await _load();
  }

  @override
  void dispose() {
    _disposed = true;
    _status?.cancel();
    _moves?.cancel();
    super.dispose();
  }
}
