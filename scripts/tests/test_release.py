"""Exercise the free release orchestration without real Apple services."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class GitHubReleaseTests(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory(prefix="macscp-github-release-")
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        (self.root / "scripts").mkdir()
        (self.root / "tools").mkdir()
        (self.root / "VERSION").write_text("1.0.0\n")
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## [1.0.0] (2026-10-25)\n\n### Highlights\n\n* Test fixture.\n")
        (self.root / ".gitignore").write_text("dist/\n.build/\nrelease.log\n")
        for name in ("release", "release-notes", "generate-appcast"):
            shutil.copyfile(ROOT / "scripts" / name, self.root / "scripts" / name)
        self.tool(self.root / "scripts/package-app", "mkdir -p .build dist/MacSCP.app\nprintf 'package\\n' >> \"$RELEASE_TEST_LOG\"")
        self.tool(self.root / "scripts/sign-app", "printf 'sign %s\\n' \"$*\" >> \"$RELEASE_TEST_LOG\"")
        self.tool(self.root / "tools/codesign", "printf 'verify\\n' >> \"$RELEASE_TEST_LOG\"\nexit \"${RELEASE_TEST_VERIFY_FAILURE:-0}\"")
        self.tool(self.root / "tools/ditto", "mkdir -p \"$2\"")
        self.tool(self.root / "tools/hdiutil", "printf 'hdiutil %s\\n' \"$1\" >> \"$RELEASE_TEST_LOG\"\nif [ \"$1\" = create ]; then\n for last; do :; done\n printf fixture > \"$last\"\nfi")
        self.log = self.root / "release.log"
        self.env = dict(os.environ, PATH=str(self.root / "tools") + os.pathsep + os.environ["PATH"],
                        RELEASE_TEST_LOG=str(self.log))
        for name in list(self.env):
            if name.startswith(("MACSCP_", "APPLE_", "MACOS_CERTIFICATE")):
                del self.env[name]
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "add", "."], cwd=self.root, check=True)
        subprocess.run(["git", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
                        "-c", "commit.gpgsign=false", "commit", "-qm", "Fixture"], cwd=self.root, check=True)

    def tool(self, path, body):
        path.write_text("#!/bin/bash\nset -euo pipefail\n" + body + "\n")
        path.chmod(0o700)

    def release(self):
        return subprocess.run(["/bin/bash", "scripts/release"], cwd=self.root,
                              env=self.env, capture_output=True, text=True)

    def test_release_needs_no_apple_credentials_and_verifies_before_packaging(self):
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stderr)
        events = self.log.read_text().splitlines()
        self.assertEqual(events[0], "package")
        self.assertTrue(events[1].startswith("sign --ad-hoc "))
        self.assertLess(events.index("verify"), events.index("hdiutil create"))
        self.assertEqual(events[-1], "hdiutil verify")

    def test_dirty_checkout_is_rejected_before_build(self):
        (self.root / "VERSION").write_text("1.0.0")
        self.assertNotEqual(self.release().returncode, 0)
        self.assertFalse(self.log.exists())

    def test_existing_release_is_not_overwritten(self):
        path = self.root / "dist/MacSCP-1.0.0.dmg"
        path.parent.mkdir()
        path.write_bytes(b"Original fixture")
        self.assertNotEqual(self.release().returncode, 0)
        self.assertEqual(path.read_bytes(), b"Original fixture")
        self.assertFalse(self.log.exists())

    def test_failed_app_verification_prevents_dmg_creation(self):
        self.env["RELEASE_TEST_VERIFY_FAILURE"] = "1"
        self.assertNotEqual(self.release().returncode, 0)
        self.assertFalse((self.root / "dist/MacSCP-1.0.0.dmg").exists())

    def test_signing_tool_diagnostics_cannot_disclose_a_malformed_secret(self):
        (self.root / "dist").mkdir()
        (self.root / ".build").mkdir()
        (self.root / "dist/MacSCP-1.0.0.dmg").write_bytes(b"Archive fixture")
        tool = self.root / ".build/sparkle/Build/Products/Release/generate_appcast"
        tool.parent.mkdir(parents=True)
        self.tool(tool, 'printf "%s" "$MACSCP_SPARKLE_PRIVATE_KEY"\nprintf "%s" "$MACSCP_SPARKLE_PRIVATE_KEY" >&2\nexit 1')
        value = "Disposable malformed fixture"
        self.env["MACSCP_SPARKLE_PRIVATE_KEY"] = value
        result = subprocess.run(["/bin/bash", "scripts/generate-appcast"], cwd=self.root,
                                env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(value not in result.stdout + result.stderr)
        self.assertFalse((self.root / "dist/appcast.xml").exists())
