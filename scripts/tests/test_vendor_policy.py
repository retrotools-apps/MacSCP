import contextlib
import importlib.machinery
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


SCRIPT = Path(__file__).resolve().parents[1] / "check-vendor"
LOADER = importlib.machinery.SourceFileLoader("vendor_policy", str(SCRIPT))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
POLICY = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(POLICY)


class VendorPolicyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.vendor = self.root / "Vendor"
        self.package = self.vendor / "dependency"
        self.package.mkdir(parents=True)
        (self.root / "Package.swift").write_text('.package(path: "Vendor/dependency")')
        (self.package / "Package.swift").write_text("// No dependencies\n")
        (self.package / "source.swift").write_text("let original = true\n")
        (self.vendor / "Package.resolved").write_text(json.dumps({"pins": [
            {"identity": "dependency", "state": {"revision": "a" * 40}}
        ]}))
        (self.vendor / "native-dependencies.json").write_text('{"pins": []}')
        self.globals = patch.multiple(POLICY, ROOT=self.root, VENDOR=self.vendor,
                                      INVENTORY=self.vendor / "checksums.json")
        self.globals.start()
        self.addCleanup(self.globals.stop)
        self.run_policy("--record")

    def run_policy(self, *arguments):
        with patch("sys.argv", [str(SCRIPT), *arguments]), contextlib.redirect_stdout(io.StringIO()):
            POLICY.main()

    def test_unchanged_local_sources_pass(self):
        self.run_policy()

    def add_native_source(self):
        root = self.vendor / "sparkle"
        root.mkdir()
        (root / "project.pbxproj").write_text("// Local native project\n")
        pin = {"identity": "sparkle", "location": "https://github.com/sparkle-project/Sparkle",
               "project": "project.pbxproj", "state": {"version": "2.9.6", "revision": "c" * 40}}
        (self.vendor / "native-dependencies.json").write_text(json.dumps({"pins": [pin]}))
        return pin

    def test_native_sources_require_the_approved_origin(self):
        pin = self.add_native_source()
        self.assertEqual(POLICY.native_pins(), [pin])
        pin["location"] = "https://example.invalid/Sparkle"
        (self.vendor / "native-dependencies.json").write_text(json.dumps({"pins": [pin]}))
        with self.assertRaisesRegex(ValueError, "unapproved native dependency origin"):
            POLICY.native_pins()

    def test_native_project_cannot_escape_its_snapshot(self):
        pin = self.add_native_source()
        pin["project"] = "../../Package.swift"
        (self.vendor / "native-dependencies.json").write_text(json.dumps({"pins": [pin]}))
        with self.assertRaisesRegex(ValueError, "escapes its snapshot"):
            POLICY.native_pins()

    def test_native_project_rejects_remote_resolution(self):
        self.add_native_source()
        (self.vendor / "sparkle/project.pbxproj").write_text('repositoryURL = "https://example.invalid/package";')
        with self.assertRaisesRegex(ValueError, "unpinned remote package"):
            POLICY.native_pins()

    def add_apple(self):
        pin = {"identity": "swift-nio", "location": "https://github.com/apple/swift-nio.git",
               "kind": "remoteSourceControl", "state": {"revision": "b" * 40, "version": "2.101.2"}}
        path = self.vendor / "Package.resolved"
        provenance = json.loads(path.read_text())
        provenance["pins"].append(pin)
        path.write_text(json.dumps(provenance))
        (self.root / "Package.resolved").write_text(json.dumps({"pins": [pin]}))
        return pin

    def test_official_apple_exact_version_passes_without_vendor_directory(self):
        self.add_apple()
        (self.package / "Package.swift").write_text(
            '.package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.2")')
        self.run_policy("--record")
        self.run_policy()
        graph = {"path": str(self.root), "dependencies": [
            {"path": str(self.package), "url": str(self.package), "identity": "dependency", "dependencies": []},
            {"path": str(self.root / ".build/checkouts/swift-nio"),
             "url": "https://github.com/apple/swift-nio.git", "version": "2.101.2",
             "identity": "swift-nio", "dependencies": []}]}
        POLICY.check_graph(graph, {"dependency"})
        graph["dependencies"][1]["url"] = "https://github.com/other/swift-nio.git"
        with self.assertRaisesRegex(ValueError, "approved source"):
            POLICY.check_graph(graph, {"dependency"})

    def test_apple_lock_revision_drift_fails(self):
        self.add_apple()
        self.run_policy("--record")
        path = self.root / "Package.resolved"
        path.write_text(path.read_text().replace("b" * 40, "c" * 40))
        with self.assertRaisesRegex(ValueError, "lock differs"):
            self.run_policy()

    def test_apple_identity_cannot_authorize_a_fork_in_provenance(self):
        self.add_apple()
        path = self.vendor / "Package.resolved"
        path.write_text(path.read_text().replace("github.com/apple/", "github.com/untrusted-fixture/"))
        with self.assertRaisesRegex(ValueError, "untrusted Apple provenance"):
            self.run_policy("--record")

    def test_apple_fork_and_unpinned_version_are_not_exempt(self):
        self.add_apple()
        for declaration in (
            '.package(url: "https://github.com/untrusted-fixture/swift-nio.git", exact: "2.101.2")',
            '.package(url: "https://github.com/apple/swift-nio.git", from: "2.101.2")',
            '.package(url: "https://github.com/apple/swift-nio.git", exact: "2.100.0")',
        ):
            (self.package / "Package.swift").write_text(declaration)
            with self.assertRaises(ValueError):
                self.run_policy("--record")

    def test_nested_swiftpm_cache_is_not_vendored(self):
        cache = self.package / ".build/checkouts/example/.git"
        cache.mkdir(parents=True)
        (cache / "config").write_text("generated cache")
        self.run_policy()

    def test_effective_graph_must_contain_only_the_recorded_local_packages(self):
        graph = {"path": str(self.root), "dependencies": [{
            "path": str(self.package), "url": str(self.package),
            "identity": "dependency", "dependencies": []
        }]}
        POLICY.check_graph(graph, {"dependency"})
        graph["dependencies"][0]["url"] = "https://example.invalid/dependency"
        with self.assertRaisesRegex(ValueError, "remote source"):
            POLICY.check_graph(graph, {"dependency"})
        graph["dependencies"][0]["path"] = str(self.root / ".build/checkouts/dependency")
        with self.assertRaisesRegex(ValueError, "outside"):
            POLICY.check_graph(graph, {"dependency"})

    def test_graph_must_include_the_complete_provenance(self):
        with self.assertRaisesRegex(ValueError, "complete dependency provenance"):
            POLICY.check_graph({"path": str(self.root), "dependencies": []}, {"dependency"})

    def test_modified_missing_and_extra_sources_fail(self):
        source = self.package / "source.swift"
        source.write_text("let modified = true\n")
        with self.assertRaisesRegex(ValueError, "inventory mismatch"):
            self.run_policy()
        source.unlink()
        with self.assertRaisesRegex(ValueError, "inventory mismatch"):
            self.run_policy()
        source.write_text("let original = true\n")
        (self.package / "injected.swift").write_text("let injected = true\n")
        with self.assertRaisesRegex(ValueError, "inventory mismatch"):
            self.run_policy()

    def test_executable_mode_changes_fail(self):
        (self.package / "source.swift").chmod(0o755)
        with self.assertRaisesRegex(ValueError, "inventory mismatch"):
            self.run_policy()

    def test_remote_registry_and_binary_dependencies_fail_even_when_recording(self):
        for declaration in ['.package(url: "https://example.invalid/a", from: "1.0.0")',
                            '.package(id: "owner.package", from: "1.0.0")',
                            '.binaryTarget(name: "binary", path: "binary.xcframework")']:
            with self.subTest(declaration=declaration):
                (self.package / "Package.swift").write_text(declaration)
                with self.assertRaises(ValueError):
                    self.run_policy("--record")

    def test_local_path_escape_fails(self):
        (self.package / "Package.swift").write_text('.package(path: "../../outside")')
        with self.assertRaisesRegex(ValueError, "escapes"):
            self.run_policy("--record")

    def test_symlink_directory_escape_fails(self):
        (self.package / "escape").symlink_to(self.root, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "symlink escapes"):
            self.run_policy("--record")

    def test_nested_git_metadata_fails(self):
        (self.package / ".git").mkdir()
        with self.assertRaisesRegex(ValueError, "Git metadata"):
            self.run_policy("--record")

    def test_comments_do_not_activate_dependencies(self):
        (self.package / "Package.swift").write_text(
            '// .package(url: "https://example.invalid/a", from: "1.0.0")\n')
        self.run_policy("--record")
        self.run_policy()


if __name__ == "__main__":
    unittest.main()
