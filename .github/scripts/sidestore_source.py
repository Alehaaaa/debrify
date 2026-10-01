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
        for shot in app.get("screenshots", []):
            url(shot, "screenshot")
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
    headline = args.commit_message.strip().splitlines()[0] if args.commit_message.strip() else ""

    new_version = {
        "version": version,
        "buildVersion": build,
        "date": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": f"Build {build} from {args.branch}@{short_sha}"
        + (f"\n\n{headline}" if headline else "")
        + f"\n\n{repo_url}/commit/{args.sha}",
        "downloadURL": args.download_url,
        "size": args.ipa.stat().st_size,
        "minOSVersion": min_os,
    }

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
    versions = ([new_version] + previous_versions)[: args.keep]

    screenshots = [
        f"{raw}/assets/screenshots/{name}"
        for name in ("search.png", "player.png", "episodes.png", "downloads.png", "stremio-catalog.png")
        if (Path("assets/screenshots") / name).is_file()
    ]

    source = {
        "name": "Debrify (commit builds)",
        "identifier": f"io.github.{args.repo.split('/')[0].lower()}.debrify.commits",
        "subtitle": f"Every commit on {args.branch}, built for sideloading.",
        "description": f"Automatic iOS builds of Debrify for each commit to {args.branch} in {args.repo}.",
        "iconURL": f"{raw}/assets/icon/app_icon_flat.png",
        "website": repo_url,
        "tintColor": "#7C4DFF",
        "featuredApps": [bundle_id],
        "apps": [
            {
                "name": "Debrify",
                "bundleIdentifier": bundle_id,
                "developerName": args.repo.split("/")[0],
                "subtitle": "Torrent search and debrid management.",
                "localizedDescription": "A modern torrent search and debrid management app.\n\n"
                "These are unsigned commit builds produced by GitHub Actions; "
                "SideStore re-signs them with your own certificate on install.",
                "iconURL": f"{raw}/assets/icon/app_icon_flat.png",
                "tintColor": "#7C4DFF",
                "category": "entertainment",
                "screenshots": screenshots,
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
