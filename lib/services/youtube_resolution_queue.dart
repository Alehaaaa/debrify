import 'dart:async';
import 'dart:collection';

/// Bounds simultaneous extraction, not viewing time or the number of videos.
/// Foreground playback takes the next free slot ahead of speculative previews.
class YoutubeResolutionQueue {
  YoutubeResolutionQueue({this.concurrency = 2}) : assert(concurrency > 0);
  final int concurrency;
  int _active = 0;
  final _foreground = Queue<void Function()>();
  final _background = Queue<void Function()>();

  Future<T> run<T>(Future<T> Function() action, {bool foreground = true}) {
    final result = Completer<T>();
    void start() {
      _active++;
      Future<T>.sync(
        action,
      ).then(result.complete, onError: result.completeError).whenComplete(() {
        _active--;
        _drain();
      });
    }

    (foreground ? _foreground : _background).add(start);
    _drain();
    return result.future;
  }

  void _drain() {
    while (_active < concurrency &&
        (_foreground.isNotEmpty || _background.isNotEmpty)) {
      (_foreground.isNotEmpty ? _foreground : _background).removeFirst()();
    }
  }
}
