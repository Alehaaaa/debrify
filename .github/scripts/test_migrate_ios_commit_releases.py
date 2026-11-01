"""Offline checks for the release migration's tag and SideStore safeguards."""

import base64
import json
import unittest

from migrate_ios_commit_releases import release_tag, update_source


class FakeGitHub:
    def __init__(self, source):
        self.source = source
        self.writes = 0

    def api(self, path, method="GET", data=None):
        if path == "contents/apps.json?ref=sidestore":
            return {
                "sha": f"source-{self.writes}",
                "content": base64.b64encode(
                    json.dumps(self.source).encode("utf-8")
                ).decode("ascii"),
            }
        if path == "contents/apps.json" and method == "PUT":
            assert data["sha"] == f"source-{self.writes}"
            self.source = json.loads(base64.b64decode(data["content"]))
            self.writes += 1
            return {}
        raise AssertionError(f"Unexpected GitHub API call {method} {path}")


class MigrationTests(unittest.TestCase):
    def setUp(self):
        self.old_url = (
            "https://github.com/Alehaaaa/debrify/releases/download/"
            "ios-commits/debrify-ios-45-61b99cf.ipa"
        )
        self.github = FakeGitHub({
            "apps": [{
                "name": "Nextup",
                "versions": [
                    {"downloadURL": self.old_url, "buildVersion": "202610010000"},
                    {"downloadURL": "https://example.com/other.ipa"},
                ],
            }],
        })

    def test_commit_tags_match_both_historical_prefixes(self):
        self.assertEqual(
            release_tag("debrify-ios-45-61b99cf.ipa"),
            ("build-45-61b99cf", "61b99cf"),
        )
        self.assertEqual(
            release_tag("nextup-ios-61-5d060f0.ipa"),
            ("build-61-5d060f0", "5d060f0"),
        )
        with self.assertRaises(RuntimeError):
            release_tag("unexpected.ipa")

    def test_rewrite_is_atomic_and_idempotent(self):
        destinations = {"debrify-ios-45-61b99cf.ipa": "build-45-61b99cf"}
        self.assertEqual(update_source(self.github, destinations), 1)
        version = self.github.source["apps"][0]["versions"][0]
        self.assertEqual(
            version["downloadURL"],
            self.old_url.replace("/ios-commits/", "/build-45-61b99cf/"),
        )
        self.assertEqual(version["buildVersion"], "202610010000")
        self.assertEqual(update_source(self.github, destinations), 0)
        self.assertEqual(self.github.writes, 1)

    def test_missing_destination_refuses_to_change_source(self):
        with self.assertRaises(RuntimeError):
            update_source(self.github, {})
        self.assertEqual(self.github.writes, 0)
        self.assertEqual(
            self.github.source["apps"][0]["versions"][0]["downloadURL"],
            self.old_url,
        )


if __name__ == "__main__":
    unittest.main()
