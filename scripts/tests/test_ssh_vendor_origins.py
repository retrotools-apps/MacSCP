"""Check original-source provenance and direct vendoring of SSH libraries."""
import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]


class SSHVendorOriginTests(unittest.TestCase):
    def test_nested_locks_use_the_root_swift_nio_pin(self):
        root_lock = json.loads((ROOT / "Package.resolved").read_text())
        root_pin = next(pin for pin in root_lock["pins"]
                        if pin["identity"] == "swift-nio")
        lock_paths = [ROOT / "Package.resolved", ROOT / "Vendor/Package.resolved"]
        lock_paths += sorted((ROOT / "Vendor").glob("*/Package.resolved"))
        self.assertIn(ROOT / "Vendor/citadel/Package.resolved", lock_paths)

        for path in lock_paths:
            lock = json.loads(path.read_text())
            pins = lock.get("pins", lock.get("object", {}).get("pins", []))
            nio_pins = [pin for pin in pins
                        if (pin.get("identity") or pin.get("package", "")).lower() == "swift-nio"]
            self.assertTrue(nio_pins, f"{path.relative_to(ROOT)} has no swift-nio pin")
            for pin in nio_pins:
                self.assertEqual(
                    pin["state"],
                    root_pin["state"],
                    f"{path.relative_to(ROOT)} has a stale swift-nio pin",
                )

    def test_source_provenance_has_no_patch_dependencies(self):
        pins = {pin["identity"]: pin for pin in
                json.loads((ROOT / "Vendor/Package.resolved").read_text())["pins"]}
        expected = {
            "citadel": ("orlandos-nl/Citadel", "0.12.1", "ae8562f895de06ccb86fdb1cbb65fd99c8976e12"),
            "swift-nio-ssh": ("Joannis/swift-nio-ssh", "0.4.0", "c997b6b12b8ef51a9b50701d98e3fab250d9a044"),
        }
        for identity, (source, version, revision) in expected.items():
            self.assertEqual(pins[identity]["location"], f"https://github.com/{source}.git")
            self.assertEqual(pins[identity]["state"], {"version": version, "revision": revision})
            self.assertEqual(set(pins[identity]), {"identity", "kind", "location", "state"})
            self.assertTrue((ROOT / "Vendor" / identity / "Sources").is_dir())
        self.assertEqual(list((ROOT / "patches").rglob("*.patch")), [])

    def test_notices_list_original_versions_and_licenses_only(self):
        notices = (ROOT / "THIRD_PARTY_NOTICES.md").read_text()
        self.assertIn("| citadel | 0.12.1 | MIT License | https://github.com/orlandos-nl/Citadel |", notices)
        self.assertIn("| swift-nio-ssh | 0.4.0 | Apache License | https://github.com/Joannis/swift-nio-ssh |", notices)
        self.assertNotIn("local patches", notices)
        self.assertNotIn("Local adaptations:", notices)

    def test_manifests_consume_the_adapted_local_sources(self):
        root = (ROOT / "Package.swift").read_text()
        citadel = (ROOT / "Vendor/citadel/Package.swift").read_text()
        self.assertIn('.package(path: "Vendor/citadel")', root)
        self.assertIn('.package(path: "Vendor/swift-nio-ssh")', root)
        self.assertIn('.package(path: "../swift-nio-ssh")', citadel)


if __name__ == "__main__":
    unittest.main()
