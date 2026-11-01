#!/usr/bin/env python3
"""Build or update a SideStore / AltStore source (apps.json) for a new IPA.

Reads the version, build number, bundle id, minimum iOS version and privacy
usage strings straight from the built Runner.app so the source always matches
what SideStore will find inside the IPA (it refuses installs on a mismatch).
New versions are prepended to the ones already published; the oldest are
dropped once there are more than --keep.
"""

import argparse
import json
import plistlib
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path


def entitlements(app: Path) -> list[str]:
    try:
        out = subprocess.run(
            ["codesign", "-d", "--entitlements", ":-", str(app)],
            capture_output=True,
            check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        return []
    if not out.strip():
        return []
    try:
        return sorted(plistlib.loads(out).keys())
    except Exception:
        return []


DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}(T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:?\d{2}))?$")
HEX_RE = re.compile(r"^#?([0-9A-Fa-f]{3}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})$")


def validate(source: dict) -> None:
    """Fail the build rather than publish something SideStore would reject.

    Mirrors the checks in SideStore's Source/StoreApp/AppVersion decoders.
    """
    def need(cond: bool, what: str) -> None:
        if not cond:
            raise SystemExit(f"invalid SideStore source: {what}")

    def url(value, what: str) -> None:
        need(isinstance(value, str) and value.startswith("https://") and " " not in value, f"{what} is not a URL")

    need(isinstance(source.get("name"), str) and source["name"], "source name missing")
    need(HEX_RE.match(source.get("tintColor", "#000")) is not None, "source tintColor")
    apps = source.get("apps")
    need(isinstance(apps, list) and apps, "no apps")
    for app in apps:
        for key in ("name", "bundleIdentifier", "developerName", "localizedDescription"):
            need(isinstance(app.get(key), str) and app[key], f"app {key} missing")
        url(app.get("iconURL"), "app iconURL")
        need(HEX_RE.match(app.get("tintColor", "#000")) is not None, "app tintColor")
        shots = app.get("screenshots", {})
        need(isinstance(shots, dict), "screenshots must be grouped by device")
        for device, items in shots.items():
            need(device in ("iphone", "ipad"), f"screenshot device {device}")
            for shot in items:
                url(shot.get("imageURL"), "screenshot")
                need(isinstance(shot.get("width"), int) and isinstance(shot.get("height"), int), "screenshot size")
        perms = app.get("appPermissions", {})
        need(all(isinstance(e, str) for e in perms.get("entitlements", [])), "entitlements")
        need(all(isinstance(v, str) and v for v in perms.get("privacy", {}).values()), "privacy usage descriptions")
        versions = app.get("versions")
        need(isinstance(versions, list) and versions, "app has no versions")
        seen = set()
        for v in versions:
            need(isinstance(v.get("version"), str) and v["version"], "version string")
            need(isinstance(v.get("buildVersion"), str), "buildVersion")
            need(isinstance(v.get("date"), str) and DATE_RE.match(v["date"]) is not None, "version date")
            url(v.get("downloadURL"), "downloadURL")
            need(isinstance(v.get("size"), int) and v["size"] > 0, "version size")
            vid = f"{v['version']}|{v['buildVersion']}"
            need(vid not in seen, f"duplicate version {vid}")
            seen.add(vid)


SCREENSHOT_DIR = Path("assets/screenshots/ios")


def png_size(path: Path) -> tuple[int, int] | None:
    head = path.read_bytes()[:24]
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        return None
    return int.from_bytes(head[16:20], "big"), int.from_bytes(head[20:24], "big")


def screenshots(raw: str) -> dict:
    """iPhone/iPad screenshots from assets/screenshots/ios/<device>/, in filename order.

    Name them 01-home.png, 02-reels.png, … to set the order. Only portrait
    PNGs taken on the device are used; anything else is skipped.
    """
    shots: dict = {}
    for device in ("iphone", "ipad"):
        items = []
        for path in sorted((SCREENSHOT_DIR / device).glob("*.png")):
            size = png_size(path)
            if not size or size[0] >= size[1]:
                continue
            items.append({
                "imageURL": f"{raw}/{path.as_posix()}",
                "width": size[0],
                "height": size[1],
            })
        if items:
            shots[device] = items
    return shots


COMMIT_RE = re.compile(r"/(?:commit/|compare/[0-9a-f]+\.\.\.)([0-9a-f]{7,40})")
MAX_CHANGES = 25


def published_sha(version: dict) -> str | None:
    """The commit a published version was built from, read back from its notes."""
    match = COMMIT_RE.search(version.get("localizedDescription", ""))
    if not match:
        return None
    try:
        return subprocess.run(
            ["git", "rev-parse", "--verify", "--quiet", match.group(1) + "^{commit}"],
            capture_output=True, text=True, check=True,
        ).stdout.strip() or None
    except (OSError, subprocess.CalledProcessError):
        return None


def changelog(previous_versions: list, sha: str, commit_message: str) -> str:
    """Commits since the previous published build, newest first."""
    since = published_sha(previous_versions[0]) if previous_versions else None
    subjects: list[str] = []
    if since and since != sha:
        try:
            out = subprocess.run(
                ["git", "log", "--no-merges", "--format=%h %s", f"{since}..{sha}"],
                capture_output=True, text=True, check=True,
            ).stdout
            subjects = [line for line in out.splitlines() if line.strip()]
        except (OSError, subprocess.CalledProcessError):
            subjects = []
    if not subjects:
        headline = commit_message.strip().splitlines()[0] if commit_message.strip() else ""
        return f"What's new:\n• {headline}" if headline else "What's new: rebuild with no new commits."
    lines = []
    for line in subjects[:MAX_CHANGES]:
        short, _, subject = line.partition(" ")
        subject = subject.replace(" [skip ci]", "")
        lines.append(f"• {subject} ({short})")
    if len(subjects) > MAX_CHANGES:
        lines.append(f"• …and {len(subjects) - MAX_CHANGES} more")
    return "What's new:\n" + "\n".join(lines)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--app", required=True, type=Path, help="Path to Runner.app")
    p.add_argument("--ipa", required=True, type=Path)
    p.add_argument("--download-url", required=True)
    p.add_argument("--previous", type=Path, help="Existing apps.json, if any")
    p.add_argument("--output", required=True, type=Path)
    p.add_argument("--repo", required=True, help="owner/name")
    p.add_argument("--branch", required=True)
    p.add_argument("--sha", required=True)
    p.add_argument("--commit-message", default="")
    p.add_argument("--keep", type=int, default=10)
    args = p.parse_args()

    info = plistlib.loads((args.app / "Info.plist").read_bytes())
    bundle_id = info["CFBundleIdentifier"]
    version = info["CFBundleShortVersionString"]
    build = str(info["CFBundleVersion"])
    min_os = info.get("MinimumOSVersion", "14.0")
    privacy = {k: v for k, v in info.items() if k.startswith("NS") and k.endswith("UsageDescription")}

    raw = f"https://raw.githubusercontent.com/{args.repo}/{args.sha}"
    repo_url = f"https://github.com/{args.repo}"
    short_sha = args.sha[:7]
    previous_versions = []
    if args.previous and args.previous.is_file():
        try:
            old = json.loads(args.previous.read_text(encoding="utf-8"))
            for app in old.get("apps", []):
                if app.get("bundleIdentifier") == bundle_id:
                    previous_versions = app.get("versions", [])
        except (ValueError, OSError):
            pass
    previous_versions = [
        v for v in previous_versions if str(v.get("buildVersion")) != build
    ]

    notes = changelog(previous_versions, args.sha, args.commit_message)
    previous_sha = published_sha(previous_versions[0]) if previous_versions else None
    link = (
        f"{repo_url}/compare/{previous_sha[:7]}...{short_sha}"
        if previous_sha and previous_sha != args.sha
        else f"{repo_url}/commit/{args.sha}"
    )

    new_version = {
        "version": version,
        "buildVersion": build,
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": f"{notes}\n\nBuild {build} from {args.branch}@{short_sha}\n{link}",
        "downloadURL": args.download_url,
        "size": args.ipa.stat().st_size,
        "minOSVersion": min_os,
    }

    versions = ([new_version] + previous_versions)[: args.keep]

    source = {
        "name": "Nextup",
        "identifier": f"io.github.{args.repo.split('/')[0].lower()}.debrify.commits",
        "subtitle": "Nextup for iPhone and iPad, built from every commit.",
        "description": "Nextup is an independent, unofficial fork of Debrify with a Reels feed, "
        "Continue Watching synced across Trakt, Simkl and MDBList, offline-first downloads "
        "and a reworked glass interface.\n\n"
        f"Every commit to {args.branch} in {args.repo} is built automatically and published "
        "here with a changelog of what changed since the previous build, so updates show up "
        "right in SideStore or AltStore. The source keeps the last few builds, so you can "
        "always roll back.\n\n"
        "Not affiliated with or endorsed by the official Debrify project.",
        "iconURL": f"{raw}/assets/icon/app_icon_flat.png",
        "website": repo_url,
        "tintColor": "#7C4DFF",
        "featuredApps": [bundle_id],
        "apps": [
            {
                "name": "Nextup",
                "bundleIdentifier": bundle_id,
                "developerName": args.repo.split("/")[0],
                "subtitle": "Your movies and shows, one swipe away.",
                "localizedDescription": "Nextup brings your cloud accounts, WebDAV servers, "
                "Stremio catalogs, IPTV and YouTube into one library, with a player built for "
                "movies and TV.\n\n"
                "• Reels: swipe through official scenes and trailers, then jump straight into the title\n"
                "• Continue Watching that follows you across Trakt, Simkl and MDBList\n"
                "• Up Next links: open any episode straight from Up Next for Trakt\n"
                "• Downloads that work fully offline, with auto-download filters\n"
                "• A glass interface with your own looks and colour palettes\n"
                "• Lock-screen controls, touch lock, pinch to fill, double-tap to pause\n"
                "• WebDAV sync with snapshots, and backups that restore cleanly\n\n"
                "Nextup doesn't host or provide any content; you connect the services you "
                "already use.\n\n"
                "These are untested builds of every commit, made by GitHub Actions. SideStore or "
                "AltStore re-signs them with your own certificate on install. Nextup is an "
                "independent fork of Debrify and isn't affiliated with the official project.",
                "iconURL": f"{raw}/assets/icon/app_icon_flat.png",
                "tintColor": "#7C4DFF",
                "category": "entertainment",
                "screenshots": screenshots(raw),
                "versions": versions,
                "appPermissions": {
                    "entitlements": entitlements(args.app),
                    "privacy": privacy,
                },
            }
        ],
        "news": [],
    }

    text = json.dumps(source, indent=2, ensure_ascii=False) + "\n"
    validate(json.loads(text))
    tmp = args.output.with_name(args.output.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    tmp.replace(args.output)
    print(f"Wrote {args.output}: {bundle_id} {version} ({build}), {len(versions)} version(s)")


if __name__ == "__main__":
    main()
