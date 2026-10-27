"""Exercise notice generation without relying on a developer's Swift cache."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ThirdPartyNoticesTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="macscp-notices-test-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        script = (ROOT / "scripts/third-party-notices").read_text()
        self.generator = script.split("<<'PYEOF'\n", 1)[1].split("\nPYEOF", 1)[0]
        self.native_identity = "sparkle-argument-parser"
        self.apple_identity = "swift-collections"
        self.write("Vendor/Package.resolved", json.dumps({"pins": [{
            "identity": self.apple_identity,
            "location": "https://github.com/apple/" + self.apple_identity,
            "state": {"version": "1.0.0"},
        }]}))
        self.write("Vendor/native-dependencies.json", json.dumps({"pins": [{
            "identity": self.native_identity,
            "location": "https://github.com/apple/swift-argument-parser",
            "state": {"version": "0.4.4"},
            "project": "Package.swift",
        }]}))
        self.write("Vendor/" + self.native_identity + "/LICENSE", "Native license fixture\n")
        self.write(".build/checkouts/" + self.apple_identity + "/LICENSE", "Apple license fixture\n")
        self.write("licenses/macSCP-upstream-MIT.txt", "Inherited license fixture\n")
        self.write("licenses/simple-icons-CC0.txt", "Icon license fixture\n")
        self.write("licenses/tabler-icons-MIT.txt", "Tabler license fixture\n")
        self.write("Sources/MacSCPAppKit/Resources/TablerOutline.json", json.dumps({
            "repository": "https://example.com/tabler", "version": "1.0.0", "revision": "fixture-revision",
        }))
        self.write("Sources/MacSCPAppKit/Resources/ApplicationLogos.json", json.dumps({
            "repository": "https://example.com/icons", "revision": "fixture",
            "additionalProviders": {"tabler-icons": {
                "repository": "https://example.com/tabler", "version": "1.0.0",
            }},
        }))

    def write(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)

    def generate(self):
        return subprocess.run([
            sys.executable, "-c", self.generator, "notices.md", "payload.json",
        ], cwd=self.root, capture_output=True, text=True, timeout=10)

    def test_native_apple_source_is_found_without_a_cached_checkout(self):
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        notices = (self.root / "notices.md").read_text()
        self.assertIn("Native license fixture", notices)
        self.assertIn("Apple license fixture", notices)

    def test_unrelated_cached_version_does_not_replace_native_license(self):
        self.write(".build/checkouts/swift-argument-parser/LICENSE", "Wrong cached license\n")
        result = self.generate()
        self.assertEqual(result.returncode, 0, result.stderr)
        notices = (self.root / "notices.md").read_text()
        self.assertIn("Native license fixture", notices)
        self.assertNotIn("Wrong cached license", notices)

    def test_missing_native_source_is_not_hidden_by_cached_checkout(self):
        (self.root / "Vendor" / self.native_identity).rename(self.root / "missing-native")
        self.write(".build/checkouts/swift-argument-parser/LICENSE", "Wrong cached license\n")
        result = self.generate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn(self.native_identity, result.stderr)
        self.assertFalse((self.root / "notices.md").exists())
