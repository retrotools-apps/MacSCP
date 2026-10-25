"""Validate release-key checks with public RFC 8032 fixtures, never real keys."""
import base64
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin", "CryptoKit requires macOS")
class SparkleKeyTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scratch = tempfile.TemporaryDirectory(prefix="macscp-key-check-")
        cls.addClassCleanup(cls.scratch.cleanup)
        cls.root = Path(cls.scratch.name)
        cls.binary = cls.root / "verify-key"
        subprocess.run(["swiftc", "-module-cache-path", str(cls.root / "modules"),
                        str(ROOT / "scripts/verify-sparkle-key.swift"), "-o", str(cls.binary)],
                       check=True, capture_output=True)
        cls.seed = base64.b64encode(bytes.fromhex(
            "9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60")).decode()
        cls.public = cls.root / "public.txt"
        cls.public.write_text(base64.b64encode(bytes.fromhex(
            "d75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a")).decode())

    def check(self, value, public=None):
        env = dict(os.environ, MACSCP_SPARKLE_PRIVATE_KEY=value)
        result = subprocess.run([str(self.binary), str(public or self.public)],
                                env=env, capture_output=True, text=True)
        self.assertTrue(not value.strip() or value.strip() not in result.stdout + result.stderr)
        return result

    def test_matching_seed_is_accepted_with_surrounding_whitespace(self):
        self.assertEqual(self.check("\n" + self.seed + "\n").returncode, 0)

    def test_malformed_or_missing_exports_fail_without_echoing_input(self):
        for value in ["", "/private/key.txt", "malformed fixture", "AA=="]:
            with self.subTest(case=len(value)):
                self.assertNotEqual(self.check(value).returncode, 0)

    def test_valid_seed_for_another_public_key_is_rejected(self):
        other = self.root / "other-public.txt"
        other.write_text(base64.b64encode(bytes(32)).decode())
        result = self.check(self.seed, other)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("does not match", result.stderr)

    def test_public_key_cannot_be_used_as_private_export(self):
        self.assertNotEqual(self.check(self.public.read_text()).returncode, 0)
