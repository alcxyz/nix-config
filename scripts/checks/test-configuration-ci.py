#!/usr/bin/env python3
"""Check CI failure propagation and credential destination boundaries."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class ConfigurationCI(unittest.TestCase):
    def test_source_access_is_required_before_running_a_command(self):
        environment = {key: value for key, value in os.environ.items() if key != "CI_SOURCE_READ_TOKEN"}
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/ci/with-source-access.sh"), "echo", "must-not-run"],
            env=environment, text=True, capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("must-not-run", result.stdout)

    def test_private_diagnostics_are_not_published_and_failure_is_preserved(self):
        result = subprocess.run(
            ["bash", str(ROOT / "scripts/ci/with-source-access.sh"), "bash", "-c", "echo fixture-diagnostic; exit 23"],
            env={**os.environ, "CI_SOURCE_READ_TOKEN": "synthetic-fixture", "CI_SOURCE_READ_USER": "fixture-user"},
            text=True, capture_output=True,
        )
        self.assertEqual(result.returncode, 23)
        self.assertNotIn("fixture-diagnostic", result.stdout + result.stderr)

    def test_git_can_invoke_the_helper_from_another_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/ci/with-source-access.sh"), "python3", "-c",
                 "import subprocess; r=subprocess.run(['git','credential','fill'], input='protocol=https\\nhost=git.alc.xyz\\n\\n', text=True, capture_output=True, check=True); assert 'password=synthetic-fixture' in r.stdout"],
                cwd=directory,
                env={**os.environ, "CI_SOURCE_READ_TOKEN": "synthetic-fixture", "CI_SOURCE_READ_USER": "fixture-user"},
                text=True, capture_output=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_evaluation_failure_prevents_native_checks(self):
        with tempfile.TemporaryDirectory() as directory:
            mock = Path(directory) / "nix"
            calls = Path(directory) / "calls"
            mock.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\nexit 19\n')
            mock.chmod(0o755)
            result = subprocess.run(
                ["bash", str(ROOT / "scripts/ci/check-configurations.sh")],
                env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"], "CALLS": str(calls)},
                capture_output=True,
            )
            self.assertEqual(result.returncode, 19)
            self.assertEqual(len(calls.read_text().splitlines()), 1)
            self.assertIn("--all-systems --no-build --no-update-lock-file", calls.read_text())

    def test_success_runs_both_phases_without_lock_updates(self):
        with tempfile.TemporaryDirectory() as directory:
            mock = Path(directory) / "nix"
            calls = Path(directory) / "calls"
            mock.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\n')
            mock.chmod(0o755)
            subprocess.run(
                ["bash", str(ROOT / "scripts/ci/check-configurations.sh")],
                env={**os.environ, "PATH": directory + os.pathsep + os.environ["PATH"], "CALLS": str(calls)},
                check=True,
            )
            commands = calls.read_text().splitlines()
            self.assertEqual(len(commands), 2)
            self.assertIn("--keep-going", commands[1])
            self.assertTrue(all("--no-update-lock-file" in command for command in commands))

    def test_credentials_are_restricted_to_the_source_host(self):
        helper = ROOT / "scripts/ci/git-source-credentials.sh"
        for operation, protocol, host, expected in [
            ("get", "https", "git.alc.xyz", "username=fixture-user\npassword=synthetic-fixture\n"),
            ("get", "https", "other.invalid", ""),
            ("get", "https", "git.alc.xyz.other.invalid", ""),
            ("get", "http", "git.alc.xyz", ""),
            ("store", "https", "git.alc.xyz", ""),
        ]:
            with self.subTest(operation=operation, protocol=protocol, host=host):
                result = subprocess.run(
                    ["bash", str(helper), operation],
                    input=f"protocol={protocol}\nhost={host}\n\n",
                    env={**os.environ, "CI_SOURCE_READ_TOKEN": "synthetic-fixture", "CI_SOURCE_READ_USER": "fixture-user"},
                    text=True, capture_output=True, check=True,
                )
                self.assertEqual(result.stdout, expected)
                self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
