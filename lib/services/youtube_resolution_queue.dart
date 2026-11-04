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
  final _queued = <Future<Object?>, void Function()>{};
  final _cancelQueued = <Future<Object?>, void Function()>{};

  Future<T> run<T>(
    Future<T> Function() action, {
    bool foreground = true,
    T Function()? onCancel,
  }) {
    final result = Completer<T>();
    void start() {
      _queued.remove(result.future);
      _cancelQueued.remove(result.future);
      _active++;
      Future<T>.sync(
        action,
      ).then(result.complete, onError: result.completeError).whenComplete(() {
        _active--;
        _drain();
      });
    }

    (foreground ? _foreground : _background).add(start);
    _queued[result.future] = start;
    if (onCancel != null) {
      _cancelQueued[result.future] = () => result.complete(onCancel());
    }
    _drain();
    return result.future;
  }

  /// Promote a queued preview when it becomes the visible reel. Its original
  /// future, extraction and consumers remain unchanged. Running work cannot
  /// be preempted, but the promoted request takes the next available slot.
  bool promote(Future<Object?> future) {
    final start = _queued[future];
    if (start == null || !_background.remove(start)) return false;
    _foreground.addFirst(start);
    _drain();
    return true;
  }

  /// A selected clip can become speculative again when the user reverses a
  /// swipe. Preserve its existing future/cache but give the next visible clip
  /// priority for scarce extraction slots.
  bool deprioritize(Future<Object?> future) {
    final start = _queued[future];
    if (start == null || !_foreground.remove(start)) return false;
    _background.add(start);
    _drain();
    return true;
  }

  /// Invalidation can cancel an extraction that has no useful consumers left
  /// before it occupies a scarce connection slot. Running work is never
  /// interrupted; cancellable callers provide a safe result via [onCancel].
  bool cancel(Future<Object?> future) {
    final start = _queued[future];
    final complete = _cancelQueued[future];
    if (start == null || complete == null) return false;
    if (!_foreground.remove(start) && !_background.remove(start)) return false;
    _queued.remove(future);
    _cancelQueued.remove(future);
    complete();
    return true;
  }

  void _drain() {
    while (_active < concurrency &&
        (_foreground.isNotEmpty || _background.isNotEmpty)) {
      (_foreground.isNotEmpty ? _foreground : _background).removeFirst()();
    }
  }
}
