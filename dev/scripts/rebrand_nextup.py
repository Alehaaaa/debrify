"""Apply presentation-only Nextup naming while retaining persistent identifiers.

Run from the repository root. Intentionally preserves method channels, bundle
identifiers, package imports, on-disk keys, link schemes and upstream credits.
"""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
LITERAL = re.compile(r"(?P<quote>['\"])(?:\\.|(?!\1).)*?(?P=quote)")


def replace_dart_literal(match: re.Match[str]) -> str:
    literal = match.group()
    if "Debrify" not in literal and "DEBRIFY" not in literal:
        return literal
    content = literal[1:-1]
    # Stable protocol, filenames, integration identifiers and upstream attribution.
    if any(part in content for part in (
        "debrify/", "debrify.", "debrify-", "debrify_", "DebrifyApp",
        "DebrifyImage", "DebrifyTv", "debrify://", "debrify.tv",
        "varunsalian", "original Debrify repo", "upstream Debrify",
    )):
        return literal
    content = content.replace("DEBRIFY", "NEXTUP").replace("Debrify", "Nextup")
    return literal[0] + content + literal[-1]


def update(path: Path, transform) -> bool:
    original = path.read_bytes()
    # Preserve CRLF and original encodings by working on UTF-8 bytes decoded
    # without universal-newline conversion.
    try:
        decoded = original.decode("utf-8")
    except UnicodeDecodeError:
        return False
    changed = transform(decoded)
    if changed == decoded:
        return False
    path.write_bytes(changed.encode("utf-8"))
    return True


def main() -> None:
    changed = []
    for path in (ROOT / "lib").rglob("*.dart"):
        if update(path, lambda source: LITERAL.sub(replace_dart_literal, source)):
            changed.append(path)

    replacements = {
        "android/app/build.gradle.kts": [('"Debrify Personal"', '"Nextup Personal"'), ('else "Debrify"', 'else "Nextup"')],
        "android/app/src/main/res/values/strings.xml": [('>Debrify</string>', '>Nextup</string>')],
        "ios/Flutter/Debug.xcconfig": [('= Debrify', '= Nextup')],
        "ios/Flutter/Release.xcconfig": [('= Debrify', '= Nextup')],
        "tvos/Flutter/Debug.xcconfig": [('DEBRIFY_APP_DISPLAY_NAME = Debrify', 'DEBRIFY_APP_DISPLAY_NAME = Nextup')],
        "tvos/Flutter/Release.xcconfig": [('DEBRIFY_APP_DISPLAY_NAME = Debrify', 'DEBRIFY_APP_DISPLAY_NAME = Nextup')],
        "ios/Runner/Info.plist": [('Debrify connects to', 'Nextup connects to')],
        "macos/Runner/Info.plist": [('Debrify connects to', 'Nextup connects to')],
        "macos/Runner/Configs/AppInfo.xcconfig": [('DEBRIFY_APP_DISPLAY_NAME = $(PRODUCT_NAME)', 'DEBRIFY_APP_DISPLAY_NAME = Nextup')],
        "web/index.html": [('content="debrify"', 'content="Nextup"'), ('<title>debrify</title>', '<title>Nextup</title>')],
        "web/manifest.json": [('"debrify"', '"Nextup"')],
        "linux/debrify.desktop": [('Name=Debrify', 'Name=Nextup')],
        "linux/runner/my_application.cc": [('"debrify"', '"Nextup"')],
        "windows/runner/main.cpp": [('L"debrify"', 'L"Nextup"')],
        "windows/runner/Runner.rc": [('"FileDescription", "debrify"', '"FileDescription", "Nextup"'), ('"ProductName", "debrify"', '"ProductName", "Nextup"')],
        ".github/workflows/ios-commit.yml": [('NAME="debrify-ios-', 'NAME="nextup-ios-'), ('name: debrify-ios-', 'name: nextup-ios-')],
        ".github/workflows/build.yml": [
            ('debrify-', 'nextup-'), ('dmg-root/Debrify.app', 'dmg-root/Nextup.app'),
            ('--volname "Debrify"', '--volname "Nextup"'),
            ('--icon "Debrify.app"', '--icon "Nextup.app"'),
            ('Name=Debrify', 'Name=Nextup'), ('X-AppImage-Name=Debrify', 'X-AppImage-Name=Nextup'),
        ],
        "windows/installer.iss": [
            ('AppName=Debrify', 'AppName=Nextup'), ('AppPublisher=Debrify', 'AppPublisher=Nextup'),
            ('AppPublisherURL=https://github.com/varunsalian/debrify', 'AppPublisherURL=https://github.com/Alehaaaa/debrify'),
            ('DefaultGroupName=Debrify', 'DefaultGroupName=Nextup'),
            ('OutputBaseFilename=debrify-', 'OutputBaseFilename=nextup-'),
            ('{group}\\\\Debrify', '{group}\\\\Nextup'), ('{autodesktop}\\\\Debrify', '{autodesktop}\\\\Nextup'),
            ('Description: "Launch Debrify"', 'Description: "Launch Nextup"'),
        ],
        "README.md": [
            ('## What is Debrify?', '## What is Nextup?'),
            ('| `debrify-<version>', '| `nextup-<version>'),
            ('chmod +x debrify-*.AppImage', 'chmod +x nextup-*.AppImage'),
            ('./debrify-*.AppImage', './nextup-*.AppImage'),
        ],
        "lib/services/continue_watching_sync_service.dart": [("$addedToNextup", "$addedToDebrify")],
        "lib/screens/video_player_screen.dart": [("isNextupTV: $isNextupTV", "isDebrifyTV: $isDebrifyTV")],
        "lib/services/webdav_sync/webdav_sync_connect_controller.dart": [("folderPath = 'Nextup'", "folderPath = 'Debrify'")],
        "lib/services/webdav_sync/webdav_sync_setup_service.dart": [("this.folderPath = 'Nextup'", "this.folderPath = 'Debrify'")],
        "lib/services/android_native_downloader.dart": [
            ("String subDir = 'Nextup'", "String subDir = 'Debrify'"),
        ],
        "lib/services/desktop_recording_service.dart": [("${sep}Nextup${sep}Recordings", "${sep}Debrify${sep}Recordings")],
        "lib/services/download_service.dart": [
            ("path.join(downloadsDir.path, 'Nextup')", "path.join(downloadsDir.path, 'Debrify')"),
            ("Download/Nextup", "Download/Debrify"),
            ("subDir: 'Nextup'", "subDir: 'Debrify'"),
            ("['Nextup',", "['Debrify',"),
            ("? 'Nextup'", "? 'Debrify'"),
            ("Directory('/storage/emulated/0/Download/Nextup')", "Directory('/storage/emulated/0/Download/Debrify')"),
        ],
        "lib/screens/download_manager_screen.dart": [("Download/Nextup/", "Download/Debrify/"), ("${sep}Nextup$sep", "${sep}Debrify$sep")],
        "lib/screens/video_player_screen.dart": [
            ("isNextupTV: $isNextupTV", "isDebrifyTV: $isDebrifyTV"),
            ("${sep}Nextup${sep}Recordings", "${sep}Debrify${sep}Recordings"),
        ],
    }
    for name, pairs in replacements.items():
        path = ROOT / name
        if update(path, lambda source: apply_pairs(source, pairs)):
            changed.append(path)
    for path in (ROOT / "lib").rglob("*.dart"):
        if update(path, lambda source: apply_pairs(source, [
            ("Downloads/Nextup", "Downloads/Debrify"),
            ("Download/Nextup", "Download/Debrify"),
            ("Nextup/Recordings", "Debrify/Recordings"),
            ("Nextup/Updates", "Debrify/Updates"),
        ])):
            changed.append(path)
    print(f"Updated {len(changed)} source and metadata files")


def apply_pairs(source: str, pairs: list[tuple[str, str]]) -> str:
    for old, new in pairs:
        source = source.replace(old, new)
    return source


if __name__ == "__main__":
    main()
