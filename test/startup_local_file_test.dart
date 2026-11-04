import 'package:debrify/services/startup_stream_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'a downloaded file opens directly, without the stream validator',
    () async {
      var direct = 0;
      final opened = await StartupStreamPolicy.openInitialMedia(
        hasResolvedUrl: true,
        hasExternalAudio: false,
        isLiveIptv: false,
        isStremioTv: false,
        isLocalFile: StartupStreamPolicy.isLocalUrl(
          Uri.file('/storage/Download/Debrify/Movie.mkv').toString(),
        ),
        openDirect: () async => direct++,
        openValidated: () async => fail('local files skip the startup gate'),
      );
      expect(opened, isTrue);
      expect(direct, 1);
    },
  );

  test('network streams keep the validator', () async {
    var validated = 0;
    await StartupStreamPolicy.openInitialMedia(
      hasResolvedUrl: true,
      hasExternalAudio: false,
      isLiveIptv: false,
      isStremioTv: false,
      isLocalFile: StartupStreamPolicy.isLocalUrl('https://cdn.example/v.mkv'),
      openDirect: () async => fail('streams are validated'),
      openValidated: () async {
        validated++;
        return true;
      },
    );
    expect(validated, 1);
    expect(StartupStreamPolicy.isLocalUrl('content://media/1'), isTrue);
  });
}
