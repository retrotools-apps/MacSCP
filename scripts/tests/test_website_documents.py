"""Behavioral checks for safe, lossless public-document presentation."""
from html.parser import HTMLParser
from pathlib import Path
import importlib.util
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("website_documents", ROOT / "scripts/website_documents.py")
renderer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(renderer)


class CodeBlocks(HTMLParser):
    def __init__(self, source):
        super().__init__(convert_charrefs=True)
        self.blocks, self.current = [], None
        self.feed(source)

    def handle_starttag(self, tag, attrs):
        if tag == "pre":
            self.current = []

    def handle_data(self, text):
        if self.current is not None:
            self.current.append(text)

    def handle_endtag(self, tag):
        if tag == "pre" and self.current is not None:
            self.blocks.append("".join(self.current))
            self.current = None


class WebsiteDocumentTests(unittest.TestCase):
    def test_license_payloads_are_preserved_without_parsing_their_headings(self):
        source = (ROOT / "THIRD_PARTY_NOTICES.md").read_text()
        expected = re.findall(r"^```\n(.*?)\n```$", source, flags=re.MULTILINE | re.DOTALL)
        html, toc = renderer.markdown(source, legal=True)
        self.assertTrue(expected)
        self.assertEqual(CodeBlocks(html).blocks, expected)
        self.assertIn(("dependencies", "Dependencies"), toc)
        self.assertNotIn("Statement of Purpose", [label for _, label in toc])

    def test_markup_and_unsafe_links_cannot_inject_html(self):
        html, _ = renderer.markdown('<script>alert("test")</script>\n\n[link](javascript:alert)\n\n`<img src=x>`')
        self.assertNotIn("<script>", html)
        self.assertNotIn("<img", html)
        self.assertNotIn('href="javascript:', html)
        self.assertIn("&lt;script&gt;", html)
        self.assertIn("<code>", html)

    def test_document_links_use_the_rendered_pages(self):
        html, _ = renderer.markdown("[Notes](CHANGELOG.md) and [notices](THIRD_PARTY_NOTICES.md)")
        self.assertIn('href="changelog.html"', html)
        self.assertIn('href="notices.html"', html)

    def test_gpl_text_is_preserved_verbatim_in_the_legal_page(self):
        source = (ROOT / "LICENSE").read_text()
        self.assertIn(source, CodeBlocks(renderer.generated_pages(ROOT)["license.html"]).blocks)

    def test_fences_require_a_closing_delimiter_and_support_language_annotations(self):
        html, _ = renderer.markdown("```text\n# Literal text\n```\n")
        self.assertEqual(CodeBlocks(html).blocks, ["# Literal text"])
        with self.assertRaises(ValueError):
            renderer.markdown("```\nIncomplete")


if __name__ == "__main__":
    unittest.main()
