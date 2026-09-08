"""Hermetic contracts for maintained dev inputs and their lock updater."""

from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
UPDATE_MAINTAINED = ROOT / "scripts/update-inputs/update-maintained.sh"
UPDATE_DMS = ROOT / "scripts/update-inputs/update-dms-plugins.sh"

DMS_INPUTS = [
    "dms-plugins",
    "danksession",
    "dms-plugins/quicksearch",
    "dms-plugins/vault",
    "dms-plugins/translate",
    "dms-plugins/spotify",
    "dms-plugins/dankcalendar",
    "dms-plugins/diskusage",
    "dms-plugins/aiusage",
    "dms-plugins/displaycontrol",
]
APP_INPUTS = ["paperflow", "grove", "canopy"]

DEV_URLS = {
    "paperflow": "github:alcxyz/paperflow/dev",
    "grove": "github:alcxyz/grove/dev",
    "canopy": "github:alcxyz/canopy/dev",
    "dms-plugins": "github:alcxyz/dms-plugins/dev",
    "quicksearch": "github:alcxyz/DankQuickSearch/dev",
    "vault": "github:alcxyz/DankVault/dev",
    "translate": "github:alcxyz/DankTranslate/dev",
    "spotify": "github:alcxyz/DankSpotify/dev",
    "dankcalendar": "github:alcxyz/DankCalendar/dev",
    "diskusage": "github:alcxyz/DankDiskUsage/dev",
    "aiusage": "github:alcxyz/DankAIUsage/dev",
    "displaycontrol": "github:alcxyz/DankDisplayControl/dev",
    "danksession": "github:alcxyz/DankSession/dev",
}

FORKED_RELEASE_INPUTS = {
    "worldclock": "WorldClock",
    "calculator": "DankCalculator",
    "screenshot": "DMS-Screenshot",
}


class MaintainedInputContracts(unittest.TestCase):
    def test_flake_uses_explicit_dev_urls_and_danksession_follow(self):
        flake = (ROOT / "flake.nix").read_text()
        for name, url in DEV_URLS.items():
            with self.subTest(input=name):
                self.assertIn(f'url = "{url}";', flake)

        self.assertIn('danksession.follows = "danksession";', flake)
        self.assertNotIn(
            'danksession.url = "github:alcxyz/DankSession/dev";', flake
        )

    def test_list_inventory_is_exact(self):
        full = subprocess.run(
            ["bash", UPDATE_MAINTAINED, "--list"],
            text=True,
            capture_output=True,
            check=True,
        )
        dms = subprocess.run(
            ["bash", UPDATE_MAINTAINED, "--dms-only", "--list"],
            text=True,
            capture_output=True,
            check=True,
        )
        self.assertEqual(full.stdout.splitlines(), DMS_INPUTS + APP_INPUTS)
        self.assertEqual(dms.stdout.splitlines(), DMS_INPUTS)

    def test_forked_plugins_keep_release_pins_and_are_not_overridden(self):
        flake = (ROOT / "flake.nix").read_text()
        lock = json.loads((ROOT / "flake.lock").read_text())
        listed = subprocess.run(
            ["bash", UPDATE_MAINTAINED, "--list"],
            text=True,
            capture_output=True,
            check=True,
        ).stdout.splitlines()

        for name, repo in FORKED_RELEASE_INPUTS.items():
            with self.subTest(input=name):
                self.assertNotIn(f"dms-plugins/{name}", listed)
                self.assertNotIn(f'{name}.url = "github:alcxyz/{repo}/dev";', flake)
                self.assertEqual(lock["nodes"][name]["original"]["repo"], repo)
                self.assertEqual(lock["nodes"][name]["original"]["ref"], "main")


class ScriptHarness(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        self.bin = self.work / "bin"
        self.bin.mkdir()
        self.calls = self.work / "nix-calls"
        self.output = self.work / "github-output"

        fake_nix = self.bin / "nix"
        fake_nix.write_text(
            textwrap.dedent(
                """\
                #!/usr/bin/env bash
                set -euo pipefail
                printf '%s\\n' "$*" >> "$FAKE_NIX_CALLS"
                case "$*" in
                  "flake update"*)
                    if [[ "${FAKE_LOCK_MODE:-unchanged}" == nested-change ]]; then
                      printf '%s\\n' '{"nodes":{"dms-plugins":{"locked":{"rev":"bundle-old"}},"aiusage":{"locked":{"rev":"nested-new"}}}}' > flake.lock
                    fi
                    ;;
                  "flake check --no-build")
                    [[ "${FAKE_CHECK_FAIL:-0}" != 1 ]]
                    ;;
                  "eval --json "*)
                    printf '%s\\n' '["dankaiusage-1.2.3"]'
                    ;;
                  "build "*)
                    [[ "${FAKE_BUILD_FAIL:-0}" != 1 ]]
                    ;;
                  *)
                    echo "unexpected nix invocation: $*" >&2
                    exit 90
                    ;;
                esac
                """
            )
        )
        fake_nix.chmod(0o755)
        self.environment = {
            **os.environ,
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "FAKE_NIX_CALLS": str(self.calls),
            "GITHUB_OUTPUT": str(self.output),
        }

    def run_script(self, script: Path, *arguments: str, **environment: str):
        return subprocess.run(
            ["bash", script, *arguments],
            cwd=self.work,
            env={**self.environment, **environment},
            text=True,
            capture_output=True,
        )

    def read_calls(self):
        if not self.calls.exists():
            return []
        return self.calls.read_text().splitlines()


class MaintainedUpdaterTests(ScriptHarness):
    def test_full_and_dms_only_select_exact_inputs(self):
        full = self.run_script(UPDATE_MAINTAINED)
        self.assertEqual(full.returncode, 0, full.stderr)
        self.assertEqual(
            self.read_calls(), ["flake update " + " ".join(DMS_INPUTS + APP_INPUTS)]
        )

        self.calls.unlink()
        dms = self.run_script(UPDATE_MAINTAINED, "--dms-only")
        self.assertEqual(dms.returncode, 0, dms.stderr)
        self.assertEqual(self.read_calls(), ["flake update " + " ".join(DMS_INPUTS)])

    def test_invalid_argument_does_not_execute_nix(self):
        result = self.run_script(UPDATE_MAINTAINED, "--unknown")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Usage:", result.stderr)
        self.assertEqual(self.read_calls(), [])


class DmsUpdaterTests(ScriptHarness):
    def setUp(self):
        super().setUp()
        scripts = self.work / "scripts/update-inputs"
        scripts.mkdir(parents=True)
        shutil.copy2(UPDATE_MAINTAINED, scripts / UPDATE_MAINTAINED.name)
        shutil.copy2(UPDATE_DMS, scripts / UPDATE_DMS.name)
        self.initial_lock = {
            "nodes": {
                "dms-plugins": {"locked": {"rev": "bundle-old"}},
                "aiusage": {"locked": {"rev": "nested-old"}},
            }
        }

    def write_lock(self):
        (self.work / "flake.lock").write_text(json.dumps(self.initial_lock))

    def test_nested_change_refreshes_when_bundle_revision_is_unchanged(self):
        self.write_lock()
        result = self.run_script(UPDATE_DMS, FAKE_LOCK_MODE="nested-change")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.read_calls(),
            [
                "flake update " + " ".join(DMS_INPUTS),
                "flake check --no-build",
                "eval --json .#homeConfigurations.alc-xyz.config.home.packages --apply xs: map (x: x.name or \"\") xs",
                "build .#homeConfigurations.alc-xyz.activationPackage --no-link",
            ],
        )
        output = self.output.read_text()
        self.assertIn("updated=true", output)
        self.assertIn("revision=bundle-old", output)
        self.assertIn("version=1.2.3", output)

    def test_unchanged_full_lock_is_a_noop(self):
        self.write_lock()
        result = self.run_script(UPDATE_DMS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_calls(), ["flake update " + " ".join(DMS_INPUTS)])
        self.assertEqual(self.output.read_text(), "updated=false\n")

    def test_validation_failure_does_not_emit_success_outputs(self):
        self.write_lock()
        result = self.run_script(
            UPDATE_DMS, FAKE_LOCK_MODE="nested-change", FAKE_CHECK_FAIL="1"
        )
        self.assertNotEqual(result.returncode, 0)
        output = self.output.read_text() if self.output.exists() else ""
        self.assertNotIn("updated=true", output)
        self.assertNotIn("version=", output)
        self.assertNotIn("revision=", output)


if __name__ == "__main__":
    unittest.main()
