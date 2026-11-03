"""Release configuration fails early without disclosing supplied values."""
from pathlib import Path
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
VALID = {
    "MACSCP_DEVELOPER_ID_P12_BASE64": "Zml4dHVyZQ==",
    "MACSCP_DEVELOPER_ID_P12_PASSWORD": "fixture-password",
    "MACSCP_NOTARY_PRIVATE_KEY": "fixture-private-key",
    "MACSCP_NOTARY_KEY_ID": "FIXTURE001",
    "MACSCP_NOTARY_ISSUER_ID": "12345678-1234-1234-1234-123456789abc",
    "MACSCP_SIGN_IDENTITY": "Developer ID Application: Fixture (TEAMFIX001)",
    "MACSCP_TEAM_ID": "TEAMFIX001",
    "MACSCP_SPARKLE_PRIVATE_KEY": "fixture-sparkle-key",
}


class ReleaseEnvironmentTests(unittest.TestCase):
    def run_check(self, environment):
        return subprocess.run(
            ["/bin/bash", str(ROOT / "scripts/check-release-environment")],
            env=environment, capture_output=True, text=True, check=False,
        )

    def test_complete_configuration_is_accepted_without_printing_values(self):
        result = self.run_check(VALID)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout + result.stderr, "")

    def test_each_missing_or_empty_setting_is_reported_without_other_values(self):
        for name in VALID:
            for empty in (False, True):
                with self.subTest(name=name, empty=empty):
                    environment = dict(VALID)
                    if empty:
                        environment[name] = ""
                    else:
                        del environment[name]
                    result = self.run_check(environment)
                    self.assertNotEqual(result.returncode, 0)
                    output = result.stdout + result.stderr
                    self.assertIn(name, output)
                    self.assertTrue(all(not value or value not in output for value in environment.values()))


if __name__ == "__main__":
    unittest.main()
