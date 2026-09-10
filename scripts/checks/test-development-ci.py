#!/usr/bin/env python3
"""Check the lightweight development gate and workflow routing."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class DevelopmentCI(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.repository = Path(self.temporary_directory.name) / "repository"
        self.repository.mkdir()
        subprocess.run(["git", "init", "--quiet", self.repository], check=True)
        subprocess.run(["git", "-C", self.repository, "config", "user.email", "fixture@example.invalid"], check=True)
        subprocess.run(["git", "-C", self.repository, "config", "user.name", "Fixture"], check=True)
        (self.repository / ".keep").write_text("fixture\n")
        subprocess.run(["git", "-C", self.repository, "add", ".keep"], check=True)
        subprocess.run(["git", "-C", self.repository, "commit", "--quiet", "-m", "base"], check=True)
        self.base = subprocess.check_output(
            ["git", "-C", self.repository, "rev-parse", "HEAD"], text=True
        ).strip()

        files = {
            "hosts/xyz/xyz-runtime-storage-policy.sh": ROOT / "hosts/xyz/xyz-runtime-storage-policy.sh",
            "scripts/ci/check-development.sh": ROOT / "scripts/ci/check-development.sh",
            "scripts/checks/forbid-submodules.sh": ROOT / "scripts/checks/forbid-submodules.sh",
            "scripts/checks/test-xyz-runtime-storage-policy.sh": ROOT
            / "scripts/checks/test-xyz-runtime-storage-policy.sh",
        }
        for destination, source in files.items():
            path = self.repository / destination
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(source, path)
        for path in [
            "scripts/checks/fixture.sh",
            "scripts/ci/fixture.sh",
            "scripts/forgejo/publish-nix-packages-lock.sh",
            "scripts/ops/fixture.sh",
            "modules/nixos/services/wolf-streaming/browser-image/fixture.sh",
            "hosts/xyz/xyz-fixture.sh",
            "scripts/checks/test-configuration-ci.py",
        ]:
            destination = self.repository / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text("fixture\n")

        self.bin = self.repository / "bin"
        self.bin.mkdir()
        tool = self.bin / "tool"
        tool.write_text(
            '#!/bin/sh\n'
            'name=$(basename "$0")\n'
            'printf "%s:%s\\n" "$name" "$*" >> "$CALLS"\n'
            'if [ "${FAIL_TOOL:-}" = "$name" ]; then exit 23; fi\n'
        )
        tool.chmod(0o755)
        for name in ["treefmt", "shellcheck", "python3", "nix"]:
            (self.bin / name).symlink_to(tool.name)
        self.calls = self.repository / "calls"
        subprocess.run(["git", "-C", self.repository, "add", "."], check=True)
        subprocess.run(["git", "-C", self.repository, "commit", "--quiet", "-m", "candidate"], check=True)

    def run_gate(self, **environment):
        return subprocess.run(
            ["bash", "scripts/ci/check-development.sh", self.base],
            cwd=self.repository,
            env={
                **os.environ,
                "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                "CALLS": str(self.calls),
                **environment,
            },
            text=True,
            capture_output=True,
        )

    def test_gate_runs_fixed_public_checks_without_nix(self):
        result = self.run_gate()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls.read_text().splitlines()
        self.assertEqual(sum(call.startswith("treefmt:") for call in calls), 2)
        self.assertEqual(sum(call.startswith("shellcheck:") for call in calls), 2)
        self.assertEqual(sum(call.startswith("python3:") for call in calls), 2)
        self.assertFalse(any(call.startswith("nix:") for call in calls))

    def test_tool_failure_stops_later_checks(self):
        result = self.run_gate(FAIL_TOOL="shellcheck")
        self.assertEqual(result.returncode, 23)
        self.assertFalse(any(call.startswith("python3:") for call in self.calls.read_text().splitlines()))

    def test_gitmodules_is_rejected_before_tools_run(self):
        (self.repository / ".gitmodules").write_text("[submodule \"fixture\"]\n")
        subprocess.run(["git", "-C", self.repository, "add", ".gitmodules"], check=True)
        subprocess.run(["git", "-C", self.repository, "commit", "--quiet", "-m", "submodule"], check=True)
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.calls.exists())

    def test_committed_whitespace_error_is_rejected_from_base_diff(self):
        (self.repository / "bad.md").write_text("trailing whitespace  \n")
        subprocess.run(["git", "-C", self.repository, "add", "bad.md"], check=True)
        subprocess.run(["git", "-C", self.repository, "commit", "--quiet", "-m", "bad whitespace"], check=True)
        result = self.run_gate()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("trailing whitespace", result.stdout + result.stderr)
        self.assertFalse(self.calls.exists())

    def test_workflow_separates_development_and_full_validation(self):
        workflow = (ROOT / ".forgejo/workflows/check-configurations.yml").read_text()
        development = "forgejo.event_name == 'pull_request' && forgejo.event.pull_request.base.ref == 'dev'"
        full = "forgejo.event_name != 'pull_request' || forgejo.event.pull_request.base.ref != 'dev'"
        ownership_gate = workflow.split("- name: Require a maintainer-owned candidate", 1)[1].split(
            "- name: Require full-validation source access", 1
        )[0]
        self.assertNotIn("if:", ownership_gate)
        self.assertIn('HEAD_REPOSITORY: ${{ forgejo.event.pull_request.head.repo.full_name }}', ownership_gate)
        self.assertEqual(workflow.count(development), 1)
        self.assertEqual(workflow.count(full), 3)
        self.assertNotIn("  push:\n", workflow)
        self.assertIn("BASE_SHA: ${{ forgejo.event.pull_request.base.sha }}", workflow)
        self.assertIn('"github:NixOS/nixpkgs/$revision#ripgrep"', workflow)
        self.assertIn('check-development.sh "$BASE_SHA"', workflow)


if __name__ == "__main__":
    unittest.main()
