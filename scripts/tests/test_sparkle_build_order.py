"""Regression tests for monotonic Sparkle release builds."""

from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/check-sparkle-build-order"


class SparkleBuildOrderTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="macscp-sparkle-build-")
        self.addCleanup(self.scratch.cleanup)
        self.appcast = Path(self.scratch.name) / "appcast.xml"
        self.appcast.write_text(
            '<?xml version="1.0"?><rss xmlns:sparkle="http://www.andymatuschak.org/'
            'xml-namespaces/sparkle"><channel><item><sparkle:version>10</sparkle:version>'
            '</item></channel></rss>'
        )

    def run_check(self, build: str):
        return subprocess.run(
            ["python3", str(SCRIPT), build, str(self.appcast)],
            capture_output=True,
            text=True,
            timeout=10,
        )

    def test_newer_build_is_accepted(self):
        result = self.run_check("11")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_equal_build_is_rejected(self):
        result = self.run_check("10")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be greater", result.stderr)

    def test_non_numeric_build_is_rejected(self):
        self.assertNotEqual(self.run_check("1.4.2").returncode, 0)


if __name__ == "__main__":
    unittest.main()
