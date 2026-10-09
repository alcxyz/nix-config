"""Hermetic contracts for released tool inputs and their lock updater (ADR-0086)."""

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
UPDATE_MAINTAINED = ROOT / "scripts/update-inputs/update-maintained.sh"

TOOL_INPUTS = ["paperless-tools", "regnskap", "reportcraft", "stashdb-pop", "videdupe"]


def list_inputs(script: Path) -> list[str]:
    return subprocess.run(
        ["bash", script, "--list"], text=True, capture_output=True, check=True
    ).stdout.splitlines()


class ToolInputContracts(unittest.TestCase):
    def test_list_inventory_is_exact(self):
        self.assertEqual(list_inputs(UPDATE_TOOLS), TOOL_INPUTS)

    def test_tools_and_maintained_apps_do_not_overlap(self):
        self.assertFalse(set(list_inputs(UPDATE_TOOLS)) & set(list_inputs(UPDATE_MAINTAINED)))

    def test_each_tool_follows_main(self):
        flake = (ROOT / "flake.nix").read_text()
        lock = json.loads((ROOT / "flake.lock").read_text())
        root_inputs = lock["nodes"]["root"]["inputs"]
        for name in TOOL_INPUTS:
            with self.subTest(input=name):
                self.assertRegex(
                    flake,
                    rf'(?m)^\s*url = "git\+ssh://git@git-ssh\.alc\.xyz/alcxyz/{re.escape(name)}\.git\?ref=main";$',
                )
                self.assertEqual(lock["nodes"][root_inputs[name]]["original"]["ref"], "main")

    def test_shortcut_calls_the_tools_updater(self):
        common = (ROOT / "users/alc/common.nix").read_text()
        self.assertRegex(
            common,
            r'(?m)^\s*tools-update\s*=\s*"bash scripts/update-inputs/update-tools\.sh";\s*$',
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

    def run_script(self, *arguments: str):
        return subprocess.run(
            ["bash", UPDATE_TOOLS, *arguments],
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

    def test_invalid_argument_does_not_execute_nix(self):
        result = self.run_script("--unknown")
        self.assertEqual(result.returncode, 2)
        self.assertIn("Usage:", result.stderr)
        self.assertEqual(self.read_calls(), [])


if __name__ == "__main__":
    unittest.main()
