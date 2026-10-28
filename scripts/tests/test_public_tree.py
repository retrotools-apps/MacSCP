"""Behavioral checks for the publication boundary, not marketing text."""
from pathlib import Path
import json
import re
import shutil
import subprocess
import tempfile
import unittest
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[2]


class PublicTreeTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="macscp-public-tree-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        shutil.copyfile(ROOT / ".gitignore", self.root / ".gitignore")

    def scan(self):
        result = subprocess.run(["python3", str(ROOT / "scripts/check-public-tree"), "--root", str(self.root)],
                                capture_output=True, text=True, check=False)
        return result.returncode, json.loads(result.stdout)

    def test_local_artifacts_are_ignored_but_public_sources_remain(self):
        for name in ["Sources/App.swift", "Sources/.env", "Sources/.codex/prompt.md", ".DS_Store",
                     "output/screenshots/private.png", "website/README.txt", "website/assets/.DS_Store"]:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture")
        code, report = self.scan()
        self.assertEqual(code, 0)
        self.assertEqual(report["issues"], [])
        self.assertGreater(report["candidateFiles"], 0)

    def test_a_force_tracked_local_file_is_not_hidden_by_gitignore(self):
        (self.root / "AGENTS.md").write_text("private instructions")
        subprocess.run(["git", "add", "-f", "AGENTS.md"], cwd=self.root, check=True)
        code, report = self.scan()
        self.assertNotEqual(code, 0)
        self.assertEqual(report["issues"][0]["path"], "AGENTS.md")

    def test_website_is_public_but_screenshot_production_stays_local(self):
        private = ["website/index.html", "website/assets/screenshots/workspace-light.png",
                   "scripts/local/screenshots/capture.swift", "output/screenshots/release/demo.png",
                   "docs/images/private.png", "docs/web/.env", "docs/web/assets/.DS_Store"]
        public = ["docs/images/readme-header.svg", "docs/USER_GUIDE.md", "Sources/App.swift",
                  "docs/index.html", "docs/.nojekyll",
                  "docs/web/index.html", "docs/web/assets/screenshots/workspace-light.webp",
                  "scripts/prepare-website", "scripts/website_documents.py",
                  "scripts/tests/test_website.py", "scripts/tests/test_website_documents.py"]
        for name in private + public:
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture")
        result = subprocess.run(["git", "ls-files", "--others", "--exclude-standard", "-z"],
                                cwd=self.root, check=True, capture_output=True)
        candidates = set(result.stdout.decode().split("\0"))
        self.assertTrue(set(public).issubset(candidates))
        self.assertTrue(set(private).isdisjoint(candidates))
        code, report = self.scan()
        self.assertEqual(code, 0)
        self.assertEqual(report["issues"], [])

    def test_readme_images_exist_and_are_not_ignored(self):
        images = re.findall(r"!\[[^]]*\]\(([^)]+)\)", (ROOT / "README.md").read_text())
        images = [name for name in images if not urlsplit(name).scheme]
        self.assertTrue(images)
        for name in images:
            path = ROOT / name
            self.assertTrue(path.is_file(), name)
            self.assertTrue(path.resolve().is_relative_to(ROOT / "docs/images") or
                            path.resolve().is_relative_to(ROOT / "docs/web/assets/screenshots"), name)
            result = subprocess.run(["git", "check-ignore", "--no-index", "--quiet", name], cwd=ROOT)
            self.assertEqual(result.returncode, 1, name)

    def test_deleted_tracked_files_are_not_publication_candidates(self):
        path = self.root / "Sources/obsolete.webp"
        path.parent.mkdir(parents=True)
        path.write_text("obsolete")
        subprocess.run(["git", "add", "Sources/obsolete.webp"], cwd=self.root, check=True)
        path.unlink()
        code, report = self.scan()
        self.assertEqual(code, 0)
        self.assertEqual(report["issues"], [])

    def test_matching_values_are_never_printed(self):
        path = self.root / "Sources/Config.swift"
        path.parent.mkdir()
        token = "ghp_" + "a" * 36
        path.write_text(token)
        code, report = self.scan()
        self.assertNotEqual(code, 0)
        self.assertNotIn(token, json.dumps(report))

    def test_external_symlinks_are_rejected(self):
        (self.root / "Sources").mkdir()
        (self.root / "Sources/external").symlink_to(self.root.parent)
        code, report = self.scan()
        self.assertNotEqual(code, 0)
        self.assertIn("escapes", report["issues"][0]["reason"])


if __name__ == "__main__":
    unittest.main()
