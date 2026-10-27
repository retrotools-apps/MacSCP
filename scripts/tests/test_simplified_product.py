"""Keep removed products out of dependency, packaging and settings surfaces."""
import json
from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SimplifiedProductTests(unittest.TestCase):
    def test_application_is_the_only_executable_with_the_expected_engine(self):
        manifest = (ROOT / "Package.swift").read_text()
        self.assertIn('.executable(name: "MacSCP", targets: ["MacSCPMain"])', manifest)
        self.assertEqual(re.findall(r'\.executable\(name: "([^"]+)"', manifest), ["MacSCP"])
        self.assertNotIn('swift-argument-parser', manifest)
        pins = json.loads((ROOT / "Vendor/Package.resolved").read_text())["pins"]
        self.assertTrue(any(pin["identity"] == "citadel" for pin in pins))

    def test_terminal_settings_offer_only_external_applications(self):
        settings = (ROOT / "Sources/MacSCPAppKit/SettingsView.swift").read_text()
        section = settings.split('private struct TerminalSettingsTab: View {', 1)[1]
        section = section.split('private struct ShortcutsSettingsTab:', 1)[0]
        for target in ["terminalApp", "iTerm", "custom"]:
            self.assertIn(f'.tag(TerminalTarget.{target})', section)
        self.assertNotIn('.builtIn', section)
        self.assertNotIn('case cli', settings)
        for locale in ["en", "de", "fr", "pl", "es", "ro", "it"]:
            catalog = ROOT / f"Sources/MacSCPAppKit/Resources/{locale}.lproj/Localizable.strings"
            self.assertIn('"settings.terminal.externalOnly.footer" = ', catalog.read_text())

    def test_packaging_and_signing_do_not_require_a_cli_binary(self):
        package = (ROOT / "scripts/package-app").read_text()
        self.assertIn('$ARM_BIN/MacSCP', package)
        self.assertNotIn('Contents/MacOS/macscp-cli', package)
        signing = (ROOT / "scripts/sign-app").read_text()
        self.assertIn('retroTools.MacSCP', signing)
        self.assertNotIn('Contents/MacOS/macscp-cli', signing)

    def test_ci_no_longer_downloads_an_unused_metal_toolchain(self):
        for workflow in ["ci.yml", "release.yml"]:
            source = (ROOT / ".github/workflows" / workflow).read_text()
            self.assertIn('swift test', source)
            self.assertNotIn('xcodebuild -downloadComponent MetalToolchain', source)

    def test_packaging_uses_distinct_architecture_trees_with_the_supported_engine(self):
        source = (ROOT / "scripts/package-app").read_text()
        self.assertIn('--build-system swiftbuild', source)
        self.assertIn('ARM_FLAGS=("${BUILD_FLAGS[@]}" --arch arm64 --scratch-path .build/package/arm64)', source)
        self.assertIn('X86_FLAGS=("${BUILD_FLAGS[@]}" --arch x86_64 --scratch-path .build/package/x86_64)', source)
        self.assertIn('swift build "${ARM_FLAGS[@]}"', source)
        self.assertIn('swift build "${X86_FLAGS[@]}"', source)


if __name__ == "__main__":
    unittest.main()
