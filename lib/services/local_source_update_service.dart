import 'dart:io';

/// Updates this personal macOS build from its local fork instead of downloading
/// a prebuilt release. The source checkout keeps the episode-link patch while
/// merging new commits from upstream.
class LocalSourceUpdateService {
  static final Directory sourceDirectory = Directory(
    '${Platform.environment['HOME']}/Documents/Programming/GitHub/debrify-nextup',
  );
  static final String flutter =
      '${Platform.environment['HOME']}/Developer/flutter-nextup/bin/flutter';
  static final String pods =
      '${Platform.environment['HOME']}/.gem/ruby/2.6.0/bin';

  static Future<bool> updateAvailable() async {
    _requireLocalToolchain();
    await _run('/usr/bin/git', [
      '-C',
      sourceDirectory.path,
      'fetch',
      'upstream',
      '+main:refs/remotes/upstream/main',
    ]);
    final base = await _output('/usr/bin/git', [
      '-C',
      sourceDirectory.path,
      'merge-base',
      'HEAD',
      'upstream/main',
    ]);
    final upstream = await _output('/usr/bin/git', [
      '-C',
      sourceDirectory.path,
      'rev-parse',
      'upstream/main',
    ]);
    return base != upstream;
  }

  /// Starts an independent helper that merges, builds, signs, replaces this
  /// app, and launches the resulting build. It terminates Debrify only after a
  /// successful build, preserving the installed app when compilation fails.
  static Future<void> buildAndInstall() async {
    _requireLocalToolchain();
    final script = File(
      '${Directory.systemTemp.path}/debrify-local-update-${DateTime.now().microsecondsSinceEpoch}.zsh',
    );
    final quotedSource = _quote(sourceDirectory.path);
    final quotedFlutter = _quote(flutter);
    final quotedPods = _quote(pods);
    await script.writeAsString('''#!/bin/zsh
set -eu
cd $quotedSource
/usr/bin/git fetch upstream +main:refs/remotes/upstream/main
if ! /usr/bin/git merge --no-edit --autostash upstream/main; then
  /usr/bin/git merge --abort || true
  /usr/bin/osascript -e 'display notification "Upstream conflicts with your fork. Merge it by hand." with title "Nextup update"' || true
  /bin/rm -f "\$0"
  exit 1
fi
/usr/bin/git push origin HEAD:nextup || true
PATH=$quotedPods:\$PATH $quotedFlutter build macos --release --build-name 0.10.0-nextup --build-number 1 --dart-define=DEBRIFY_LOCAL_VALIDATION=false || exit 1
app=build/macos/Build/Products/Release/debrify.app
/usr/bin/xattr -cr "\$app"
/usr/bin/codesign --force --deep --sign - "\$app"
/usr/bin/killall debrify || true
/usr/bin/ditto "\$app" /Applications/Debrify.app
/usr/bin/xattr -cr /Applications/Debrify.app
/usr/bin/codesign --force --deep --sign - /Applications/Debrify.app
/usr/bin/open /Applications/Debrify.app
/bin/rm -f "\$0"
''');
    await Process.start('/bin/zsh', [
      script.path,
    ], mode: ProcessStartMode.detached);
  }

  static void _requireLocalToolchain() {
    if (!sourceDirectory.existsSync() || !File(flutter).existsSync()) {
      throw const LocalSourceUpdateException(
        'Local Nextup source or Flutter SDK is missing.',
      );
    }
  }

  static Future<void> _run(String command, List<String> arguments) async {
    final result = await Process.run(command, arguments);
    if (result.exitCode != 0) {
      throw LocalSourceUpdateException(result.stderr.toString().trim());
    }
  }

  static Future<String> _output(String command, List<String> arguments) async {
    final result = await Process.run(command, arguments);
    if (result.exitCode != 0) {
      throw LocalSourceUpdateException(result.stderr.toString().trim());
    }
    return result.stdout.toString().trim();
  }

  static String _quote(String value) =>
      "'${value.replaceAll("'", "'\\\"'\\\"'")}'";
}

class LocalSourceUpdateException implements Exception {
  final String message;
  const LocalSourceUpdateException(this.message);
}
