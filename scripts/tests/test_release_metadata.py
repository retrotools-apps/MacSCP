"""Verify MacSCP's curated release metadata and third-party bootstrap notice."""
from pathlib import Path
import shutil
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ReleaseMetadataTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pdf_path = ROOT / "output/pdf/THIRD_PARTY_NOTICES.pdf"
        result = subprocess.run([
            "swift", "-module-cache-path", str(ROOT / ".build/notices-module-cache"),
            str(ROOT / "scripts/render-notices-pdf.swift"), "--text", str(cls.pdf_path),
        ], capture_output=True, text=True, timeout=60, cwd=ROOT, check=True)
        cls.pdf_text = re.sub(r"MacSCP - Third-party licenses\s+\d+", "", result.stdout)

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="macscp-release-test-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        (self.root / "scripts").mkdir()
        self.script = self.root / "scripts/release-notes"
        shutil.copyfile(ROOT / "scripts/release-notes", self.script)
        (self.root / "VERSION").write_text("0.1.0\n")
        (self.root / "CHANGELOG.md").write_text(
            "# Changelog\n\n## [0.1.0] (2026-10-20)\n\n### Features\n\n"
            "* **test:** Current change.\n\n## [0.0.9] (2026-10-19)\n\n### Features\n\n"
            "* **test:** Older change.\n")

    def run_notes(self, *args):
        return subprocess.run(["python3", str(self.script), *args], capture_output=True,
                              text=True, timeout=10)

    def test_tagged_notes_do_not_include_upstream_or_older_releases(self):
        result = self.run_notes("v0.1.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Current change.", result.stdout)
        self.assertNotIn("Older change.", result.stdout)

    def test_default_version_comes_from_version_file(self):
        self.assertEqual(self.run_notes().stdout, self.run_notes("0.1.0").stdout)

    def test_mismatched_tag_is_rejected(self):
        result = self.run_notes("v1.6.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")

    def test_missing_changelog_section_is_rejected(self):
        (self.root / "CHANGELOG.md").write_text("# Changelog\n")
        self.assertNotEqual(self.run_notes().returncode, 0)

    def test_application_license_and_bootstrap_notice_are_both_preserved(self):
        inherited = (ROOT / "licenses/macSCP-upstream-MIT.txt").read_text()
        self.assertIn("Copyright (c) 2026 noix", inherited)
        notice = (ROOT / "licenses/macSCP-NOTICE.txt").read_text()
        self.assertIn("SPDX-License-Identifier: GPL-3.0-or-later", notice)
        canonical = (ROOT / "LICENSE").read_text()
        self.assertTrue(canonical.lstrip().startswith("GNU GENERAL PUBLIC LICENSE"))
        self.assertIn("Version 3, 29 June 2007", canonical)
        self.assertIn("17. Interpretation of Sections 15 and 16.", canonical)
        self.assertIn(inherited.rstrip(), (ROOT / "THIRD_PARTY_NOTICES.md").read_text())
        package = (ROOT / "scripts/package-app").read_text()
        self.assertIn('cp output/pdf/THIRD_PARTY_NOTICES.pdf "$APP/Contents/Resources/THIRD_PARTY_NOTICES.pdf"', package)
        self.assertNotIn('cp THIRD_PARTY_NOTICES.md ', package)
        self.assertIn('cp LICENSE "$APP/Contents/Resources/LICENSE"', package)
        self.assertIn('cp licenses/macSCP-NOTICE.txt "$APP/Contents/Resources/NOTICE"', package)

    def test_readable_notices_preserve_license_text_without_developer_instructions(self):
        self.assertTrue(self.pdf_path.read_bytes().startswith(b"%PDF-"))
        self.assertIn("Third-party licenses", self.pdf_text)
        normalized = "".join(self.pdf_text.split())
        inherited = "".join((ROOT / "licenses/macSCP-upstream-MIT.txt").read_text().split())
        self.assertIn(inherited, normalized)
        for phrase in ["This file is generated", "Do not edit it by hand", "scripts/third-party-notices", "column is a guess"]:
            self.assertNotIn(phrase, self.pdf_text)
        self.assertNotIn(b"/JavaScript", self.pdf_path.read_bytes())

    def test_pdf_preserves_every_license_block_in_the_markdown_inventory(self):
        blocks = []
        current = None
        fence = None
        for line in (ROOT / "THIRD_PARTY_NOTICES.md").read_text().splitlines():
            if fence is None and line.startswith("```") and set(line) == {"`"}:
                fence, current = line, []
            elif fence is not None and line == fence:
                blocks.append("\n".join(current).rstrip("\n"))
                fence, current = None, None
            elif current is not None:
                current.append(line)
        self.assertTrue(blocks)
        normalized = "".join(self.pdf_text.split())
        for block in blocks:
            self.assertIn("".join(block.split()), normalized)

    def test_packaging_does_not_derive_a_version_from_upstream_tags(self):
        for filename in ["package-app", "release"]:
            source = (ROOT / "scripts" / filename).read_text()
            self.assertIn('VERSION="${MACSCP_VERSION:-$(< VERSION)}"', source)
            self.assertNotIn("git describe --tags", source)

    def test_workflow_extracts_curated_notes_without_regenerating_history(self):
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn('python3 scripts/release-notes "$TAG"', workflow)
        self.assertNotIn("conventional-changelog-cli", workflow)
        self.assertNotIn("git push origin HEAD:main", workflow)


if __name__ == "__main__":
    unittest.main()
