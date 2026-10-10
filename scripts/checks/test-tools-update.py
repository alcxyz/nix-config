"""Hermetic contracts for released and dev tool and app inputs and their lock updaters (ADR-0086, ADR-0087, ADR-0089)."""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[2]
UPDATE_TOOLS = ROOT / "scripts/update-inputs/update-tools.sh"
UPDATE_DEV_TOOLS = ROOT / "scripts/update-inputs/update-dev-tools.sh"
UPDATE_MAINTAINED = ROOT / "scripts/update-inputs/update-maintained.sh"
UPDATE_APPS = ROOT / "scripts/update-inputs/update-apps.sh"

TOOL_INPUTS = ["paperless-tools", "regnskap", "reportcraft", "stashdb-pop", "videdupe", "t3rry"]
# Tools whose canonical repository is on GitHub rather than Forgejo.
GITHUB_TOOLS = {"t3rry"}
# Each dev input is the same repository as a released tool input, on `dev`.
DEV_TOOL_INPUTS = {
    "paperless-tools-dev": "paperless-tools",
    "regnskap-dev": "regnskap",
    "t3rry-dev": "t3rry",
}
APP_INPUTS = ["grove", "canopy", "bivrost"]
# Dev builds of released apps; dev-apps-update (update-maintained.sh) refreshes them.
DEV_APP_INPUTS = {"grove-dev": "grove", "canopy-dev": "canopy", "bivrost-dev": "bivrost"}


def list_inputs(script: Path) -> list[str]:
    return subprocess.run(
        ["bash", script, "--list"], text=True, capture_output=True, check=True
    ).stdout.splitlines()


class ToolInputContracts(unittest.TestCase):
    def test_list_inventory_is_exact(self):
        self.assertEqual(list_inputs(UPDATE_TOOLS), TOOL_INPUTS)

    def test_dev_list_inventory_is_exact(self):
        self.assertEqual(list_inputs(UPDATE_DEV_TOOLS), list(DEV_TOOL_INPUTS))

    def test_dev_inputs_pair_with_released_tools(self):
        self.assertLessEqual(set(DEV_TOOL_INPUTS.values()), set(TOOL_INPUTS))

    def test_app_list_inventory_is_exact(self):
        self.assertEqual(list_inputs(UPDATE_APPS), APP_INPUTS)

    def test_dev_apps_pair_with_released_apps(self):
        self.assertLessEqual(set(DEV_APP_INPUTS.values()), set(APP_INPUTS))
        self.assertLessEqual(set(DEV_APP_INPUTS), set(list_inputs(UPDATE_MAINTAINED)))

    def test_update_lists_do_not_overlap(self):
        scripts = (UPDATE_TOOLS, UPDATE_DEV_TOOLS, UPDATE_MAINTAINED, UPDATE_APPS)
        lists = [set(list_inputs(script)) for script in scripts]
        for i, first in enumerate(lists):
            for second in lists[i + 1 :]:
                self.assertFalse(first & second)

    def assert_follows(self, name, repository, ref):
        flake = (ROOT / "flake.nix").read_text()
        lock = json.loads((ROOT / "flake.lock").read_text())
        node = lock["nodes"][lock["nodes"]["root"]["inputs"][name]]
        self.assertRegex(
            flake,
            rf'(?m)^\s*{re.escape(name)} = \{{\n\s*url = "git\+ssh://git@git-ssh\.alc\.xyz/alcxyz/{re.escape(repository)}\.git\?ref={ref}";$',
        )
        self.assertEqual(node["original"]["ref"], ref)

    def assert_tool_follows(self, name, repository, ref):
        if repository in GITHUB_TOOLS:
            self.assert_github_follows(name, repository, ref)
        else:
            self.assert_follows(name, repository, ref)

    def test_each_tool_follows_main(self):
        for name in TOOL_INPUTS:
            with self.subTest(input=name):
                self.assert_tool_follows(name, name, "main")

    def test_each_dev_tool_follows_dev(self):
        for name, repository in DEV_TOOL_INPUTS.items():
            with self.subTest(input=name):
                self.assert_tool_follows(name, repository, "dev")

    def assert_github_follows(self, name, repository, ref):
        flake = (ROOT / "flake.nix").read_text()
        lock = json.loads((ROOT / "flake.lock").read_text())
        node = lock["nodes"][lock["nodes"]["root"]["inputs"][name]]
        self.assertRegex(
            flake,
            rf'(?m)^\s*{re.escape(name)} = \{{\n\s*url = "github:alcxyz/{re.escape(repository)}/{ref}";$',
        )
        self.assertEqual(node["original"]["ref"], ref)

    def test_each_app_follows_main(self):
        for name in APP_INPUTS:
            with self.subTest(input=name):
                self.assert_github_follows(name, name, "main")

    def test_each_dev_app_follows_dev(self):
        for name, repository in DEV_APP_INPUTS.items():
            with self.subTest(input=name):
                self.assert_github_follows(name, repository, "dev")

    def test_dev_builds_take_only_a_dev_name(self):
        overlay = (ROOT / "flake/pkgs.nix").read_text()
        renamed = {**DEV_APP_INPUTS, "t3rry-dev": "t3rry"}
        for name, repository in renamed.items():
            with self.subTest(app=name):
                self.assertRegex(
                    overlay,
                    rf'writeShellScriptBin "{name}" \'\'\n\s*exec \$\{{\w+\.default\}}/bin/{repository} "\$@"\n',
                )

    def test_paperweight_dev_keeps_its_own_state(self):
        overlay = (ROOT / "flake/pkgs.nix").read_text()
        self.assertIn('writeShellScriptBin "paperweight-dev"', overlay)
        self.assertRegex(overlay, r'export XDG_STATE_HOME="[^"]*/paperweight-dev"')

    def test_shortcuts_call_the_updaters(self):
        common = (ROOT / "users/alc/common.nix").read_text()
        shortcuts = (
            ("tools-update", "update-tools"),
            ("dev-tools-update", "update-dev-tools"),
            ("apps-update", "update-apps"),
            ("dev-apps-update", "update-maintained"),
        )
        for alias, script in shortcuts:
            with self.subTest(alias=alias):
                self.assertRegex(
                    common,
                    rf'(?m)^\s*{alias}\s*=\s*"bash scripts/update-inputs/{script}\.sh";\s*$',
                )


class ToolUpdaterTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        bin_dir = self.work / "bin"
        bin_dir.mkdir()
        self.calls = self.work / "nix-calls"
        bash = shutil.which("bash")
        self.assertIsNotNone(bash)
        fake_nix = bin_dir / "nix"
        fake_nix.write_text(
            textwrap.dedent(
                f"""\
                #!{bash}
                printf '%s\\n' "$*" >> "$FAKE_NIX_CALLS"
                """
            )
        )
        fake_nix.chmod(0o755)
        self.environment = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FAKE_NIX_CALLS": str(self.calls),
        }

    def run_script(self, *arguments: str, script: Path = UPDATE_TOOLS):
        return subprocess.run(
            ["bash", script, *arguments],
            cwd=self.work,
            env=self.environment,
            text=True,
            capture_output=True,
        )

    def read_calls(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def test_updates_exactly_the_tool_inputs(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_calls(), ["flake update " + " ".join(TOOL_INPUTS)])

    def test_dev_updater_updates_exactly_the_dev_inputs(self):
        result = self.run_script(script=UPDATE_DEV_TOOLS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_calls(), ["flake update " + " ".join(DEV_TOOL_INPUTS)])

    def test_app_updater_updates_exactly_the_app_inputs(self):
        result = self.run_script(script=UPDATE_APPS)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_calls(), ["flake update " + " ".join(APP_INPUTS)])

    def test_invalid_argument_does_not_execute_nix(self):
        for script in (UPDATE_TOOLS, UPDATE_DEV_TOOLS, UPDATE_APPS):
            with self.subTest(script=script.name):
                result = self.run_script("--unknown", script=script)
                self.assertEqual(result.returncode, 2)
                self.assertIn("Usage:", result.stderr)
                self.assertEqual(self.read_calls(), [])


if __name__ == "__main__":
    unittest.main()
