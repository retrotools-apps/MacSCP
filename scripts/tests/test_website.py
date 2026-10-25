"""Offline checks for MacSCP's factual static website and legal documents."""
import hashlib
from html.parser import HTMLParser
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
from urllib.parse import unquote, urlsplit

ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / "docs/web"


class Document(HTMLParser):
    def __init__(self, text):
        super().__init__()
        self.ids, self.links, self.images = [], [], []
        self.feed(text)

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if "id" in attrs:
            self.ids.append(attrs["id"])
        if tag == "a" and "href" in attrs:
            self.links.append(attrs["href"])
        if tag in {"img", "script", "link"}:
            source = attrs.get("src") or attrs.get("href")
            if source:
                self.links.append(source)
        if tag == "img":
            self.images.append(attrs)


class WebsiteTests(unittest.TestCase):
    def test_generated_public_documents_are_current(self):
        result = subprocess.run(["python3", str(ROOT / "scripts/prepare-website"), "--check"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((SITE / "LICENCE.md").read_bytes(), (ROOT / "LICENSE").read_bytes())

    def test_canonical_application_licence_preserves_the_gpl_text(self):
        licence = (ROOT / "LICENSE").read_text()
        self.assertIn("SPDX-License-Identifier: GPL-3.0-or-later", (ROOT / "licenses/macSCP-NOTICE.txt").read_text())
        body = licence
        self.assertIn("GNU GENERAL PUBLIC LICENSE", body)
        self.assertIn("17. Interpretation of Sections 15 and 16.", body)
        # SHA-256 of https://www.gnu.org/licenses/gpl-3.0.txt, retrieved verbatim.
        self.assertEqual(hashlib.sha256(body.encode()).hexdigest(),
                         "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986")

    def test_every_local_link_and_fragment_resolves_inside_the_static_site(self):
        for page in SITE.glob("*.html"):
            document = Document(page.read_text())
            self.assertEqual(len(document.ids), len(set(document.ids)), page.name)
            for link in document.links:
                with self.subTest(page=page.name, link=link):
                    url = urlsplit(link)
                    if url.scheme or url.netloc:
                        self.assertEqual(url.scheme, "https")
                        continue
                    target = (page.parent / unquote(url.path)).resolve() if url.path else page
                    self.assertTrue(target.is_relative_to(SITE), "Link escapes website root")
                    self.assertTrue(target.is_file(), target)
                    if url.fragment and target.suffix == ".html":
                        self.assertIn(unquote(url.fragment), Document(target.read_text()).ids)
            for image in document.images:
                self.assertIn("alt", image)

    def test_release_version_and_download_destination_are_consistent(self):
        index = (SITE / "index.html").read_text()
        version = (ROOT / "VERSION").read_text().strip()
        self.assertEqual(set(re.findall(r'data-version>([^<]+)', index)), {version})
        self.assertIn("https://github.com/retrotools-apps/MacSCP/releases", Document(index).links)
        screenshots = [image for image in Document(index).images if image["src"].endswith(".png")]
        self.assertTrue(screenshots)
        for image in screenshots:
            content = (SITE / image["src"]).read_bytes()
            self.assertEqual(content[:8], bytes([137, 80, 78, 71, 13, 10, 26, 10]))

    def test_animations_are_optional_and_no_runtime_network_client_is_added(self):
        script = (SITE / "script.js").read_text()
        self.assertIn("document.querySelector('#year')", script)
        self.assertIn("IntersectionObserver", script)
        self.assertIn("prefers-reduced-motion: reduce", script)
        self.assertNotRegex(script, r"\b(?:fetch|XMLHttpRequest|WebSocket)\s*\(")
        self.assertIn("@media(prefers-reduced-motion:reduce)", (SITE / "macscp.css").read_text())

    def test_guide_navigation_has_its_own_visibility_rule(self):
        guide = (SITE / "guide.html").read_text()
        self.assertIn('class="wrap guide-main"', guide)
        self.assertIn('class="guide-nav"', guide)
        self.assertRegex((SITE / "macscp.css").read_text(),
                         r"\.guide-main\s+\.guide-nav\s+a\s*\{[^}]*display:\s*inline")

    def test_source_links_use_the_project_repository(self):
        for page in ["index.html", "guide.html"]:
            self.assertIn("https://github.com/retrotools-apps/MacSCP",
                          Document((SITE / page).read_text()).links)

    def test_deployment_export_contains_public_assets_but_not_local_notes(self):
        with tempfile.TemporaryDirectory(prefix="macscp-site-export-") as directory:
            output = Path(directory) / "site"
            result = subprocess.run(["python3", str(ROOT / "scripts/prepare-website"), "--output", str(output)],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((output / "index.html").is_file())
            self.assertFalse((output / "README.txt").exists())
            self.assertFalse(list(output.rglob(".DS_Store")))
            for page in output.glob("*.html"):
                for link in Document(page.read_text()).links:
                    url = urlsplit(link)
                    if not url.scheme and url.path:
                        self.assertTrue((page.parent / unquote(url.path)).is_file())

    def test_deployment_export_does_not_overwrite_an_existing_directory(self):
        with tempfile.TemporaryDirectory(prefix="macscp-site-existing-") as directory:
            sentinel = Path(directory) / "keep.txt"
            sentinel.write_text("existing content")
            result = subprocess.run(["python3", str(ROOT / "scripts/prepare-website"), "--output", directory],
                                    capture_output=True, text=True, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(sentinel.read_text(), "existing content")


if __name__ == "__main__":
    unittest.main()
