import 'dart:async';

import 'package:background_downloader/background_downloader.dart';
import 'package:debrify/services/download_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('retrying desktop transfer startup does not duplicate observers', () async {
    final service = DownloadService.instance;
    final updates = StreamController<TaskUpdate>.broadcast(sync: true);
    final delivered = <TaskProgressUpdate>[];
    final subscription = service.progressStream.listen(delivered.add);
    addTearDown(() async {
      await service.debugDetachPluginUpdates();
      await subscription.cancel();
      await updates.close();
    });

    // Register once, then repeat the same registration as when startup throws
    // after trackTasks() and initialize() retries. The service owns one stream
    // subscription independently of how often a screen requests initialization.
    service.debugObservePluginUpdates(updates.stream);
    service.debugObservePluginUpdates(updates.stream);

    final task = DownloadTask(
      taskId: 'observer-retry',
      url: 'https://example.com/file.mkv',
      filename: 'file.mkv',
    );
    updates.add(TaskProgressUpdate(task, .4));
    await Future<void>.delayed(Duration.zero);
    expect(delivered, hasLength(1));
    expect(delivered.single.progress, .4);

    // Shutdown removes ownership, including queued broadcast deliveries.
    await service.debugDetachPluginUpdates();
    updates.add(TaskProgressUpdate(task, .6));
    await Future<void>.delayed(Duration.zero);
    expect(delivered, hasLength(1));

    // A new process-local observer can be registered after explicit teardown.
    service.debugObservePluginUpdates(updates.stream);
    updates.add(TaskProgressUpdate(task, .8));
    await Future<void>.delayed(Duration.zero);
    expect(delivered, hasLength(2));
    expect(delivered.last.progress, .8);
  });

  test(
    'detaching an observer invalidates an authorization callback in flight',
    () async {
      final service = DownloadService.instance;
      final updates = StreamController<TaskUpdate>.broadcast(sync: true);
      final delivered = <TaskProgressUpdate>[];
      final subscription = service.progressStream.listen(delivered.add);
      addTearDown(() async {
        await service.debugDetachPluginUpdates();
        await subscription.cancel();
        await updates.close();
      });

      service.debugObservePluginUpdates(updates.stream);
      updates.add(
        TaskProgressUpdate(
          DownloadTask(
            taskId: 'detached-in-flight',
            url: 'https://example.com/video.mkv',
            filename: 'video.mkv',
          ),
          .5,
        ),
      );
      // The listener is awaiting its authorization decision. Canceling the
      // subscription cannot cancel an async callback that has already begun.
      await service.debugDetachPluginUpdates();
      await Future<void>.delayed(Duration.zero);
      expect(delivered, isEmpty);
    },
  );

  test('profile handoff rejects a callback from the previous view', () async {
    final service = DownloadService.instance;
    final updates = StreamController<TaskUpdate>.broadcast(sync: true);
    final delivered = <TaskProgressUpdate>[];
    final subscription = service.progressStream.listen(delivered.add);
    addTearDown(() async {
      service.finishProfileSwitch();
      await service.debugDetachPluginUpdates();
      await subscription.cancel();
      await updates.close();
    });

    service.debugObservePluginUpdates(updates.stream);
    updates.add(
      TaskProgressUpdate(
        DownloadTask(
          taskId: 'previous-profile-event',
          url: 'https://example.com/video.mkv',
          filename: 'video.mkv',
        ),
        .2,
      ),
    );
    await service.prepareProfileSwitch();
    service.finishProfileSwitch();
    await Future<void>.delayed(Duration.zero);
    expect(delivered, isEmpty);

    updates.add(
      TaskProgressUpdate(
        DownloadTask(
          taskId: 'new-profile-event',
          url: 'https://example.com/new.mkv',
          filename: 'new.mkv',
        ),
        .8,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(delivered.single.progress, .8);
  });
}
