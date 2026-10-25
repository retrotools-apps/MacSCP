"""Real Ed25519 verification with disposable keys, never a maintainer Keychain."""
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class AppcastVerificationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.work = tempfile.TemporaryDirectory(prefix="macscp-appcast-test-")
        cls.addClassCleanup(cls.work.cleanup)
        cls.root = Path(cls.work.name)
        cls.verifier = cls.root / "verify"
        subprocess.run(["swiftc", "-module-cache-path", str(cls.root / "modules"),
                        str(ROOT / "scripts/verify-appcast.swift"), "-o", str(cls.verifier)],
                       check=True, capture_output=True)
        cls.fixture = cls.root / "fixture.swift"
        cls.fixture.write_text('''import CryptoKit
import Foundation
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
let other = Curve25519.Signing.PrivateKey()
let archive = Data("Disposable archive fixture".utf8)
try archive.write(to: root.appendingPathComponent("MacSCP-1.0.0.dmg"))
try key.publicKey.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("key"), atomically: true, encoding: .utf8)
try other.publicKey.rawRepresentation.base64EncodedString().write(to: root.appendingPathComponent("other-key"), atomically: true, encoding: .utf8)
let signature = try key.signature(for: archive).base64EncodedString()
for variant in ["valid", "wrong-build", "wrong-url", "missing-archive-signature", "unsigned", "tampered-feed"] {
    let build = variant == "wrong-build" ? "2" : "1"
    let url = variant == "wrong-url" ? "https://example.com/unexpected.dmg" : "https://github.com/retrotools-apps/MacSCP/releases/download/v1.0.0/MacSCP-1.0.0.dmg"
    let archiveSignature = variant == "missing-archive-signature" ? "" : signature
    var xml = Data("<rss xmlns:sparkle='http://www.andymatuschak.org/xml-namespaces/sparkle'><channel><item><sparkle:version>\\(build)</sparkle:version><sparkle:shortVersionString>1.0.0</sparkle:shortVersionString><enclosure url='\\(url)' length='\\(archive.count)' sparkle:edSignature='\\(archiveSignature)'/></item></channel></rss>\\n".utf8)
    if variant != "unsigned" {
        let feedSignature = try key.signature(for: xml).base64EncodedString()
        xml.append(Data("<!-- sparkle-signatures:\\nedSignature: \\(feedSignature)\\nlength: \\(xml.count)\\n-->\\n".utf8))
    }
    if variant == "tampered-feed" { xml[1] = 120 }
    try xml.write(to: root.appendingPathComponent(variant + ".xml"))
}
''')
        subprocess.run(["swift", "-module-cache-path", str(cls.root / "modules"),
                        str(cls.fixture), str(cls.root)], check=True, capture_output=True)
        cls.app = cls.root / "MacSCP.app"
        (cls.app / "Contents").mkdir(parents=True)
        with (cls.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleVersion": "1", "CFBundleShortVersionString": "1.0.0",
                          "SUPublicEDKey": (cls.root / "key").read_text(),
                          "SURequireSignedFeed": True, "SUVerifyUpdateBeforeExtraction": True}, stream)

    def verify(self, variant="valid", key="key", archive=None):
        return subprocess.run([str(self.verifier), str(self.root / (variant + ".xml")),
                               str(archive or self.root / "MacSCP-1.0.0.dmg"), str(self.app), str(self.root / key)],
                              capture_output=True, text=True)

    def test_valid_feed_and_archive_are_accepted(self):
        result = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_unsigned_tampered_and_inconsistent_feeds_are_rejected(self):
        for variant in ("wrong-build", "wrong-url", "missing-archive-signature", "unsigned", "tampered-feed"):
            with self.subTest(variant=variant):
                self.assertNotEqual(self.verify(variant).returncode, 0)

    def test_wrong_public_key_is_rejected(self):
        self.assertNotEqual(self.verify(key="other-key").returncode, 0)

    def test_tampered_archive_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix="macscp-altered-archive-") as scratch:
            path = Path(scratch) / "MacSCP-1.0.0.dmg"
            path.write_bytes(b"Modified archive fixture")
            self.assertNotEqual(self.verify(archive=path).returncode, 0)
