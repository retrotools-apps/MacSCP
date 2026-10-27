"""Security regression guards for the privileged GitHub release workflow."""
from pathlib import Path
import os
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/release.yml"


class ReleaseWorkflowSecurityTests(unittest.TestCase):
    @staticmethod
    def resolver_script():
        workflow = WORKFLOW.read_text()
        block = workflow.split("        id: release\n", 1)[1].split("\n\n  preflight:\n", 1)[0]
        script = block.split("        run: |\n", 1)[1]
        return textwrap.dedent(script)

    def test_release_source_is_resolved_before_secret_bearing_jobs(self):
        workflow = WORKFLOW.read_text()

        self.assertIn("  workflow_dispatch:\n", workflow)
        self.assertNotIn("  push:\n", workflow)
        self.assertIn('gh api "repos/$GITHUB_REPOSITORY/git/ref/tags/$TAG"', workflow)
        self.assertIn('if [[ "$OBJECT_TYPE" != commit', workflow)
        self.assertIn('compare/$OBJECT_SHA...$DEFAULT_BRANCH', workflow)
        self.assertIn('echo "commit=$OBJECT_SHA" >> "$GITHUB_OUTPUT"', workflow)

        immutable_checkout = 'ref: ${{ needs.resolve.outputs.commit }}'
        self.assertEqual(workflow.count(immutable_checkout), 4)
        self.assertNotIn('ref: ${{ github.event.inputs.tag || github.ref_name }}', workflow)

    def test_every_secret_or_publication_job_uses_the_protected_environment(self):
        workflow = WORKFLOW.read_text()

        for job, next_job in (("preflight", "store"), ("build", "publish")):
            section = workflow.split(f"  {job}:\n", 1)[1].split(f"  {next_job}:\n", 1)[0]
            self.assertIn("    environment: release\n", section)
            self.assertIn("secrets.MACSCP_SPARKLE_PRIVATE_KEY", section)

        publish = workflow.split("  publish:\n", 1)[1]
        self.assertIn("    environment: release\n", publish)
        self.assertIn("      contents: write\n", publish)
        self.assertIn('CURRENT_TAG_OBJECT="$(gh api ', publish)
        self.assertIn('EXPECTED_TAG_OBJECT: ${{ needs.resolve.outputs.tag_object }}', publish)

    def test_resolver_accepts_an_annotated_release_tag_and_rejects_other_ref_forms(self):
        script = self.resolver_script()
        tag_object = "a" * 40
        commit = "b" * 40
        fake_gh = f"""#!/bin/bash
        case "$*" in
          *git/ref/tags/v1.2.0*) printf '%s\\n' '{{"object":{{"type":"tag","sha":"{tag_object}"}}}}' ;;
          *git/tags/{tag_object}*) printf '%s\\n' '{{"object":{{"type":"commit","sha":"{commit}"}}}}' ;;
          *compare/{commit}...main*) printf '%s\\n' 'ahead' ;;
          *) exit 2 ;;
        esac
        """
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gh = root / "gh"
            gh.write_text(textwrap.dedent(fake_gh))
            gh.chmod(0o700)
            output = root / "output"
            env = dict(os.environ,
                       PATH=f"{root}:{os.environ['PATH']}",
                       REQUESTED_TAG="v1.2.0",
                       DEFAULT_BRANCH="main",
                       EVENT_NAME="workflow_dispatch",
                       GITHUB_REF="refs/heads/main",
                       GITHUB_REPOSITORY="retrotools-apps/MacSCP",
                       GITHUB_OUTPUT=str(output))
            accepted = subprocess.run(["/bin/bash", "-c", script], env=env,
                                      text=True, capture_output=True)
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
            self.assertEqual(output.read_text().splitlines(), [
                "tag=v1.2.0",
                f"commit={commit}",
                f"tag_object={tag_object}",
            ])

            for rejected_ref in ("main", "refs/tags/v1.2.0", commit):
                env["REQUESTED_TAG"] = rejected_ref
                rejected = subprocess.run(["/bin/bash", "-c", script], env=env,
                                          text=True, capture_output=True)
                self.assertNotEqual(rejected.returncode, 0)
                self.assertIn("must be a bare semantic-version tag", rejected.stdout)

            env["REQUESTED_TAG"] = "v1.2.0"
            env["GITHUB_REF"] = "refs/heads/untrusted-release"
            rejected_branch = subprocess.run(["/bin/bash", "-c", script], env=env,
                                             text=True, capture_output=True)
            self.assertNotEqual(rejected_branch.returncode, 0)
            self.assertIn("must be dispatched from the default branch", rejected_branch.stdout)


if __name__ == "__main__":
    unittest.main()
