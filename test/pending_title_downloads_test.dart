import 'package:debrify/services/downloads/pending_title_downloads.dart';
import 'package:flutter_test/flutter_test.dart';

PendingTitleDownload _entry(String id, {String type = 'movie'}) =>
    PendingTitleDownload(
      id: id,
      title: 'Title $id',
      type: type,
      phase: PendingDownloadPhase.searching,
    );

void main() {
  setUp(PendingTitleDownloads.resetForTesting);

  test('a run shows from begin until end, moving through its phases', () {
    final token = PendingTitleDownloads.begin(_entry('tt1'));
    expect(
      PendingTitleDownloads.entries.value['tt1']?.phase,
      PendingDownloadPhase.searching,
    );

    PendingTitleDownloads.update(token, 'tt1', PendingDownloadPhase.checking);
    expect(
      PendingTitleDownloads.entries.value['tt1']?.phase,
      PendingDownloadPhase.checking,
    );

    PendingTitleDownloads.update(token, 'tt1', PendingDownloadPhase.adding);
    expect(
      PendingTitleDownloads.entries.value['tt1']?.phase.label,
      'Adding source',
    );

    PendingTitleDownloads.end(token, 'tt1');
    expect(PendingTitleDownloads.entries.value, isEmpty);
  });

  test('an older run never updates or clears a newer run for the title', () {
    final first = PendingTitleDownloads.begin(_entry('tt1'));
    final second = PendingTitleDownloads.begin(_entry('tt1'));

    PendingTitleDownloads.update(first, 'tt1', PendingDownloadPhase.adding);
    expect(
      PendingTitleDownloads.entries.value['tt1']?.phase,
      PendingDownloadPhase.searching,
    );

    PendingTitleDownloads.end(first, 'tt1');
    expect(PendingTitleDownloads.entries.value, contains('tt1'));

    PendingTitleDownloads.end(second, 'tt1');
    expect(PendingTitleDownloads.entries.value, isEmpty);
  });

  test('titles are tracked independently and changes notify listeners', () {
    var notified = 0;
    void listener() => notified++;
    PendingTitleDownloads.entries.addListener(listener);
    addTearDown(() => PendingTitleDownloads.entries.removeListener(listener));

    final a = PendingTitleDownloads.begin(_entry('tt1'));
    PendingTitleDownloads.begin(_entry('tt2', type: 'series'));
    PendingTitleDownloads.end(a, 'tt1');

    expect(PendingTitleDownloads.entries.value.keys, ['tt2']);
    expect(PendingTitleDownloads.entries.value['tt2']?.type, 'series');
    expect(notified, 3);
  });
}
