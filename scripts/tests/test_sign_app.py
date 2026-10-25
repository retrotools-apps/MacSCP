"""Validate signing argument/entitlement wiring without real signing identities."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest


class SigningTests(unittest.TestCase):
    def test_packaged_identity_matches_the_executable_and_exported_types(self):
        package = (Path(__file__).resolve().parents[1] / "package-app").read_text()
        document = package.split("<<PLIST\n", 1)[1].split("\nPLIST", 1)[0]
        version = (Path(__file__).resolve().parents[2] / "VERSION").read_text().strip()
        document = document.replace("${VERSION}", version).replace("${BUILD}", "1")
        metadata = plistlib.loads(document.encode())
        self.assertEqual(metadata["CFBundleIdentifier"], "retroTools.MacSCP")
        self.assertEqual(set(metadata["CFBundleLocalizations"]), {"en", "de", "fr", "pl", "es", "ro", "it"})
        self.assertEqual(metadata["CFBundleShortVersionString"], version)
        for key in ["CFBundleName", "CFBundleDisplayName", "CFBundleExecutable"]:
            self.assertEqual(metadata[key], "MacSCP")
        for exported in metadata["UTExportedTypeDeclarations"]:
            self.assertTrue(exported["UTTypeIdentifier"].startswith("retroTools.MacSCP."))

    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="macscp-sign-test-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.script = Path(__file__).resolve().parents[1] / "sign-app"
        self.app = self.root / "MacSCP.app"
        for folder in ["MacOS", "Resources/macSCP_MacSCPAppKit.bundle", "Resources/macSCP_macSCPCore.bundle"]:
            (self.app / "Contents" / folder).mkdir(parents=True, exist_ok=True)
        for binary in ["MacSCP"]:
            (self.app / "Contents/MacOS" / binary).touch()
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "retroTools.MacSCP", "MacSCPDistribution": "direct"}, stream)
        tools = self.root / "tools"
        tools.mkdir()
        security = tools / "security"
        security.write_text("#!/bin/sh\nprintf '%s\\n' '1) fixture Apple Development: Fixture'\n")
        security.chmod(0o700)
        codesign = tools / "codesign"
        codesign.write_text("""#!/usr/bin/env python3
import json, os, plistlib, sys
args = sys.argv[1:]
if '-dvv' in args:
    if os.environ.get('SIGN_TEST_ADHOC'):
        print('Signature=adhoc\\nTeamIdentifier=not set')
    else:
        print('TeamIdentifier=' + os.environ['MACSCP_TEAM_ID'])
    if os.environ.get('SIGN_TEST_VERBOSE_TAIL'):
        print('fixture signature details ' * 10000)
if '--force' in args:
    data = {}
    if '--entitlements' in args:
        with open(args[args.index('--entitlements') + 1], 'rb') as stream:
            data = plistlib.load(stream)
    with open(os.environ['SIGN_TEST_LOG'], 'a') as stream:
        stream.write(json.dumps({'arguments': args, 'entitlements': data}) + '\\n')
""")
        codesign.chmod(0o700)
        self.log = self.root / "signing.jsonl"
        self.env = dict(os.environ, PATH=str(tools) + os.pathsep + os.environ["PATH"],
                        MACSCP_SIGN_IDENTITY="Apple Development: Fixture", MACSCP_TEAM_ID="TESTTEAM01",
                        SIGN_TEST_LOG=str(self.log))

    def run_script(self, *args):
        return subprocess.run(["/bin/bash", str(self.script), *(args or [str(self.app)])], env=self.env,
                              capture_output=True, text=True, timeout=20)

    def test_app_uses_only_the_current_credential_group(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        records = [json.loads(line) for line in self.log.read_text().splitlines()]
        records = [r for r in records if '--identifier' in r['arguments']]
        self.assertEqual(len(records), 1)
        self.assertEqual({r["entitlements"]["com.apple.application-identifier"] for r in records},
                         {"TESTTEAM01.retroTools.MacSCP"})
        for record in records:
            self.assertEqual(record["entitlements"]["keychain-access-groups"],
                             ["TESTTEAM01.retroTools.MacSCP.credentials"])
            self.assertNotIn("com.apple.security.app-sandbox", record["entitlements"])
            self.assertIn("runtime", record["arguments"])
            self.assertIn("--timestamp=none", record["arguments"])
            self.assertEqual(record["arguments"][record["arguments"].index("--identifier") + 1], "retroTools.MacSCP")

    def test_development_executable_has_a_stable_identity_without_restricted_entitlements(self):
        binary = self.app / "Contents/MacOS/MacSCP"
        binary.chmod(0o700)
        result = self.run_script("--executable", str(binary))
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(self.log.read_text())
        args = record["arguments"]
        self.assertEqual(args[args.index("--identifier") + 1], "retroTools.MacSCP")
        self.assertEqual(record["entitlements"], {})
        self.assertNotIn('--entitlements', args)

    def test_preflight_checks_identity_without_signing_anything(self):
        self.assertEqual(self.run_script("--check").returncode, 0)
        self.assertFalse(self.log.exists())

    def test_verbose_signing_output_cannot_cause_a_false_team_mismatch(self):
        self.env['SIGN_TEST_VERBOSE_TAIL'] = '1'
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_explicit_ad_hoc_app_needs_no_apple_identity_or_restricted_entitlements(self):
        self.env.pop("MACSCP_SIGN_IDENTITY")
        self.env.pop("MACSCP_TEAM_ID")
        self.env["SIGN_TEST_ADHOC"] = "1"
        (self.root / "tools/security").write_text("#!/bin/sh\nexit 99\n")
        for relative in ("Autoupdate", "Updater.app"):
            (self.app / "Contents/Frameworks/Sparkle.framework/Versions/B" / relative).mkdir(parents=True)
        result = self.run_script("--ad-hoc", str(self.app))
        self.assertEqual(result.returncode, 0, result.stderr)
        records = [json.loads(line) for line in self.log.read_text().splitlines()]
        self.assertTrue(records)
        targets = [r["arguments"][-1] for r in records]
        self.assertLess(targets.index(str(self.app / "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate")),
                        targets.index(str(self.app / "Contents/Frameworks/Sparkle.framework")))
        self.assertEqual(targets[-1], str(self.app))
        for record in records:
            args = record["arguments"]
            self.assertEqual(args[args.index("--sign") + 1], "-")
            self.assertNotIn("--options", args)
            self.assertNotIn("--entitlements", args)
            self.assertEqual(record["entitlements"], {})

    def test_ad_hoc_signing_cannot_be_used_for_a_store_package(self):
        with (self.app / "Contents/Info.plist").open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "retroTools.MacSCP", "MacSCPDistribution": "app-store"}, stream)
        self.assertNotEqual(self.run_script("--ad-hoc", str(self.app)).returncode, 0)
        self.assertFalse(self.log.exists())

    def test_ad_hoc_identity_is_rejected(self):
        self.env["MACSCP_SIGN_IDENTITY"] = "-"
        result = self.run_script("--check")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ad-hoc", result.stderr)
        self.assertFalse(self.log.exists())

    def test_invalid_team_stops_before_signing(self):
        self.env["MACSCP_TEAM_ID"] = "invalid;team"
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertFalse(self.log.exists())

    def test_missing_identity_is_not_created_implicitly(self):
        self.env["MACSCP_SIGN_IDENTITY"] = "Missing identity"
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assertFalse(self.log.exists())

    def test_github_release_rejects_store_distribution_before_any_signing(self):
        environment = self.env.copy()
        environment.pop("MACSCP_SIGN_IDENTITY", None)
        environment["MACSCP_DISTRIBUTION"] = "app-store"
        result = subprocess.run(["/bin/bash", str(self.script.parent / "release")], env=environment,
                                capture_output=True, text=True, timeout=20)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Store", result.stderr)
        self.assertFalse(self.log.exists())


if __name__ == "__main__":
    unittest.main()
