"""Offline regression guards for source-built, signed direct updates."""
import base64
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


class SparkleUpdatesTests(unittest.TestCase):
    def test_only_the_public_ed25519_key_is_packaged(self):
        public = (ROOT / "Resources/Sparkle-public-key.txt").read_text().strip()
        self.assertEqual(len(base64.b64decode(public, validate=True)), 32)
        package = (ROOT / "scripts/package-app").read_text()
        self.assertIn("SUPublicEDKey", package)
        self.assertIn("SURequireSignedFeed", package)
        self.assertIn("SUVerifyUpdateBeforeExtraction", package)
        self.assertIn("SUSignedFeedFailureExpirationInterval integer 0", package)
        self.assertIn("SUAllowsAutomaticUpdates", package)

    def test_store_build_excludes_linking_embedding_and_external_ui(self):
        manifest = (ROOT / "Package.swift").read_text()
        self.assertIn('let withSparkle = !storeBuild', manifest)
        package = (ROOT / "scripts/package-app").read_text()
        self.assertIn("-DMACSCP_APP_STORE", package)
        self.assertIn('unset MACSCP_ENABLE_SPARKLE', package)
        self.assertIn('test ! -e "$APP/Contents/Frameworks/Sparkle.framework"', package)
        self.assertIn('otool -L', package)

    def test_build_uses_local_sources_without_binary_package_targets(self):
        build = (ROOT / "scripts/build-sparkle").read_text()
        self.assertIn("Vendor/sparkle/Sparkle.xcodeproj", build)
        self.assertIn("-disableAutomaticPackageResolution", build)
        self.assertFalse((ROOT / "Vendor/sparkle/Package.swift").exists())
        project = (ROOT / "Vendor/sparkle/Sparkle.xcodeproj/project.pbxproj").read_text()
        self.assertIn('relativePath = "../sparkle-argument-parser"', project)
        self.assertNotIn("repositoryURL =", project)

    def test_helpers_are_signed_before_the_framework_and_app(self):
        sign = (ROOT / "scripts/sign-app").read_text()
        self.assertLess(sign.index('"$SPARKLE/Versions/B/Autoupdate"'), sign.index('"$SPARKLE/Versions/B/Updater.app"'))
        self.assertLess(sign.index('"$SPARKLE/Versions/B/Updater.app"'), sign.index('"$SPARKLE"\n'))

    def test_hardened_development_build_signs_its_linked_framework(self):
        source = (ROOT / "scripts/sign-app").read_text()
        self.assertIn('/usr/bin/otool -L "$TARGET"', source)
        self.assertIn('"/Sparkle.framework/"', source)
        self.assertIn('/.build/sparkle/Build/Products/Release/Sparkle.framework', source)
        self.assertIn('codesign --verify --deep --strict "$SPARKLE"', source)
        self.assertNotIn('disable-library-validation', source)

    def test_release_publishes_a_signed_feed_without_private_keys_in_arguments(self):
        source = (ROOT / "scripts/generate-appcast").read_text()
        self.assertIn('--ed-key-file -', source)
        self.assertIn('--account retroTools.MacSCP.updates', source)
        self.assertIn('releases/download/v${VERSION}/', source)
        workflow = (ROOT / ".github/workflows/release.yml").read_text()
        self.assertIn("secrets.MACSCP_SPARKLE_PRIVATE_KEY", workflow)
        self.assertIn("dist/appcast.xml", workflow)
        self.assertIn("github.run_number", workflow)
        build_step = workflow.split("- name: Build ad-hoc signed GitHub DMG\n", 1)[1].split("\n      - name:", 1)[0]
        sign_step = workflow.split("- name: Sign Sparkle appcast\n", 1)[1].split("\n      - name:", 1)[0]
        self.assertNotIn("MACSCP_SPARKLE_PRIVATE_KEY", build_step)
        self.assertIn("MACSCP_SPARKLE_PRIVATE_KEY", sign_step)
