#!/usr/bin/env python3
"""Move legacy ios-commits IPAs to per-commit releases without breaking SideStore.

Dry-run by default. Apply with GH_TOKEN and --apply; optionally remove the old
rolling release after every IPA and SideStore URL has been verified. Re-running
the migration is safe: existing destination assets are checked, not overwritten.
"""

import argparse
import base64
import hashlib
import json
import os
import re
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


LEGACY_TAG = "ios-commits"
SOURCE_BRANCH = "sidestore"
IPA_RE = re.compile(r"^(?:debrify|nextup)-ios-(\d+)-([0-9a-f]{7})\.ipa$")


class GitHub:
    def __init__(self, repo: str, token: str = ""):
        self.repo = repo
        self.token = token
        self.api_root = f"https://api.github.com/repos/{repo}"

    def request(self, url: str, method: str = "GET", data=None, accept=None):
        headers = {
            "Accept": accept or "application/vnd.github+json",
            "User-Agent": "nextup-release-migration",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        payload = None
        if data is not None:
            payload = json.dumps(data).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(
            url, data=payload, headers=headers, method=method
        )
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                body = response.read()
                return json.loads(body) if body else None
        except urllib.error.HTTPError as exc:
            if exc.code == 404 and method == "GET":
                return None
            raise RuntimeError(f"GitHub {method} request failed (HTTP {exc.code}): {url}") from exc

    def api(self, path: str, method: str = "GET", data=None):
        return self.request(f"{self.api_root}/{path}", method, data)

    def fetch_asset(self, asset: dict, destination: Path) -> str:
        # Use the API asset endpoint so private repositories work as well.
        url = f"{self.api_root}/releases/assets/{asset['id']}"
        headers = {
            "Accept": "application/octet-stream",
            "User-Agent": "nextup-release-migration",
        }
        if self.token:
            headers["Authorization"] = f"Bearer {self.token}"
        request = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(request, timeout=300) as response:
            # Some API clients get JSON metadata rather than the binary asset.
            if "json" in response.headers.get("Content-Type", ""):
                raise RuntimeError(f"GitHub returned metadata instead of {asset['name']}")
            digest = hashlib.sha256()
            with destination.open("wb") as output:
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
                    digest.update(chunk)
        if destination.stat().st_size != asset["size"]:
            raise RuntimeError(f"Download size mismatch: {asset['name']}")
        if asset.get("digest") and asset["digest"] != f"sha256:{digest.hexdigest()}":
            raise RuntimeError(f"Download digest mismatch: {asset['name']}")
        return digest.hexdigest()

    def upload_asset(self, release: dict, path: Path) -> dict:
        target = (
            f"https://uploads.github.com/repos/{self.repo}/releases/"
            f"{release['id']}/assets?{urllib.parse.urlencode({'name': path.name})}"
        )
        headers = {
            "Accept": "application/vnd.github+json",
            "User-Agent": "nextup-release-migration",
            "X-GitHub-Api-Version": "2022-11-28",
            "Authorization": f"Bearer {self.token}",
            "Content-Type": "application/octet-stream",
        }
        request = urllib.request.Request(
            target, data=path.read_bytes(), headers=headers, method="POST"
        )
        try:
            with urllib.request.urlopen(request, timeout=300) as response:
                return json.load(response)
        except urllib.error.HTTPError as exc:
            raise RuntimeError(f"Could not upload {path.name} (HTTP {exc.code})") from exc


def release_tag(asset_name: str) -> tuple[str, str]:
    match = IPA_RE.fullmatch(asset_name)
    if not match:
        raise RuntimeError(f"Unknown legacy IPA naming convention: {asset_name}")
    return f"build-{match.group(1)}-{match.group(2)}", match.group(2)


def read_source(api: GitHub) -> tuple[dict, dict]:
    info = api.api(f"contents/apps.json?ref={SOURCE_BRANCH}")
    if info is None:
        raise RuntimeError("SideStore apps.json is missing; refusing to rewrite URLs")
    contents = base64.b64decode(info["content"]).decode("utf-8")
    return info, json.loads(contents)


def update_source(api: GitHub, destinations: dict[str, str]) -> int:
    # A concurrent iOS publish may update the branch; retry with the new SHA.
    for attempt in range(5):
        info, source = read_source(api)
        replacements = 0
        for app in source.get("apps", []):
            for version in app.get("versions", []):
                old = version.get("downloadURL", "")
                url = urllib.parse.urlsplit(old)
                parts = url.path.split("/")
                if len(parts) < 3 or parts[-2] != LEGACY_TAG:
                    continue
                asset_name = parts[-1]
                if asset_name not in destinations:
                    raise RuntimeError(f"Source points to an IPA not in the migration: {asset_name}")
                version["downloadURL"] = old.replace(
                    f"/releases/download/{LEGACY_TAG}/",
                    f"/releases/download/{destinations[asset_name]}/",
                )
                replacements += 1
        if not replacements:
            return 0
        encoded = base64.b64encode(
            (json.dumps(source, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
        ).decode("ascii")
        try:
            api.api("contents/apps.json", "PUT", {
                "message": "Point historical SideStore builds to per-commit releases",
                "content": encoded,
                "sha": info["sha"],
                "branch": SOURCE_BRANCH,
            })
            return replacements
        except RuntimeError as exc:
            if "HTTP 409" not in str(exc) or attempt == 4:
                raise
    raise RuntimeError("Could not update SideStore source")


def migrate(repo: str, apply: bool, remove_legacy: bool) -> None:
    token = os.environ.get("GH_TOKEN", "").strip()
    if apply and not token:
        raise SystemExit("--apply requires GH_TOKEN with contents:write permission")
    api = GitHub(repo, token)
    old = api.api(f"releases/tags/{LEGACY_TAG}")
    if old is None:
        raise SystemExit(f"No legacy release tagged {LEGACY_TAG}")
    assets = [asset for asset in old["assets"] if asset["name"].endswith(".ipa")]
    destinations: dict[str, str] = {}
    for asset in assets:
        tag, short_sha = release_tag(asset["name"])
        destinations[asset["name"]] = tag
        print(f"{asset['name']} ({asset['size']} bytes) -> {tag}")
    if not assets:
        raise SystemExit("No IPA assets in the legacy release")
    print(f"{len(assets)} IPA files discovered; apply={apply}")
    if not apply:
        return

    with tempfile.TemporaryDirectory(prefix="nextup-migrate-") as tempdir:
        for asset in assets:
            name = asset["name"]
            tag, short_sha = release_tag(name)
            release = api.api(f"releases/tags/{tag}")
            if release is None:
                commit = api.api(f"commits/{short_sha}")
                if commit is None:
                    raise RuntimeError(f"Could not resolve the commit for {name}")
                release = api.api("releases", "POST", {
                    "tag_name": tag,
                    "target_commitish": commit["sha"],
                    "name": f"Nextup build #{tag.split('-')[1]} ({short_sha})",
                    "body": f"Historical iOS build from {commit['sha']}. Android APKs were not built for this commit.",
                    "prerelease": True,
                })
            path = Path(tempdir) / name
            actual_digest = api.fetch_asset(asset, path)
            existing = next(
                (item for item in release["assets"] if item["name"] == name), None
            )
            if existing is None:
                existing = api.upload_asset(release, path)
            if existing["size"] != asset["size"]:
                raise RuntimeError(f"Destination size mismatch: {tag}/{name}")
            if existing.get("digest"):
                if existing["digest"] != f"sha256:{actual_digest}":
                    raise RuntimeError(f"Destination digest mismatch: {tag}/{name}")
            else:
                # GitHub did not expose a digest; verify actual downloaded bytes.
                check_path = Path(tempdir) / f"verified-{name}"
                if api.fetch_asset(existing, check_path) != actual_digest:
                    raise RuntimeError(f"Destination contents differ: {tag}/{name}")
            print(f"Verified {tag}/{name}")

    print(f"Rewrote {update_source(api, destinations)} SideStore download URLs")
    _, final_source = read_source(api)
    for app in final_source.get("apps", []):
        for version in app.get("versions", []):
            if f"/releases/download/{LEGACY_TAG}/" in version.get("downloadURL", ""):
                raise RuntimeError("SideStore still references the legacy release")
    if remove_legacy:
        # All source URLs now resolve to checksum-verified copies.
        api.api(f"releases/{old['id']}", "DELETE")
        print(f"Removed legacy release {LEGACY_TAG}; its git tag remains for history")
    else:
        print(f"Legacy release {LEGACY_TAG} retained; pass --remove-legacy to remove it")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="Alehaaaa/debrify")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--remove-legacy", action="store_true")
    arguments = parser.parse_args()
    if arguments.remove_legacy and not arguments.apply:
        parser.error("--remove-legacy requires --apply")
    migrate(arguments.repo, arguments.apply, arguments.remove_legacy)
