#!/usr/bin/env python3
"""Exercise the generated workspace wrapper and activation with invented data."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile


def main():
    case = json.loads(Path(sys.argv[1]).read_text())
    fixture = Path(tempfile.mkdtemp(prefix="workspace-consumer-"))
    root = fixture / case["root"]
    wrapper = Path(case["wrapper"])
    try:
        env = os.environ.copy()
        env.update(
            HOME=str(fixture / "home"),
            GIT_CONFIG_NOSYSTEM="1",
            GIT_CONFIG_GLOBAL="/dev/null",
            GIT_TERMINAL_PROMPT="0",
            GIT_CONFIG_COUNT="0",
        )
        Path(env["HOME"]).mkdir()
        hostile_path = fixture / "hostile-path"
        hostile_path.mkdir()
        fake_git = hostile_path / "git"
        fake_git.write_text("#!/bin/sh\nexit 97\n")
        fake_git.chmod(0o755)
        env["PATH"] = str(hostile_path) + os.pathsep + env["PATH"]

        def invoke(*args, code=0):
            result = subprocess.run(
                [str(wrapper), *args], cwd=fixture, env=env, text=True, capture_output=True
            )
            assert result.returncode == code, (args, result)
            return result

        # Read the manifest actually passed by the generated wrapper.
        command = next(
            shlex.split(line) for line in wrapper.read_text().splitlines()
            if line.strip().startswith("exec ")
        )
        assert case["root"] in command, command
        assert command[1] == case["executable"], command
        assert command[-1] == "$@", command
        manifest_path = next(p for p in command if p.endswith("-workspace-manifest.json"))
        manifest = json.loads(Path(manifest_path).read_text())
        assert manifest == {
            "directories": case["expectedDirectories"],
            "repositories": case["expectedRepositories"],
            "links": case["expectedLinks"],
        }, manifest
        assert case["git"].rsplit("/", 1)[0] in wrapper.read_text()

        help_result = invoke("--help")
        assert "workspace-sync [--status | --directories]" in help_result.stdout
        assert invoke("-h").stdout == help_result.stdout
        unknown = invoke("--unknown", code=2)
        assert "unknown argument: --unknown" in unknown.stderr
        assert not root.exists()

        status = invoke("--status")
        assert "0 existing, 1 missing, 0 skipped" in status.stdout
        assert not root.exists(), "status created a fresh root"

        # Run only the generated directory activation entry, never a profile.
        activation = Path(case["activation"]).read_text()
        assert shlex.split(activation) == [str(wrapper), "--directories"]
        subprocess.run(["bash", case["activation"]], cwd=fixture, env=env, check=True)
        for directory in manifest["directories"]:
            assert (root / directory).is_dir(), directory
        assert not (root / "apps/selected").exists(), "activation cloned"
        assert not (root / "aliases/selected").is_symlink(), "activation linked"
        invoke("--directories")

        source = fixture / "source repository"
        git = case["git"]

        def run_git(*args):
            return subprocess.run([git, *args], cwd=fixture, env=env, check=True, capture_output=True)

        run_git("init", "-q", "-b", "fixture-branch", str(source))
        (source / "tracked").write_text("original\n")
        run_git("-C", str(source), "add", "tracked")
        run_git("-C", str(source), "-c", "user.name=Fixture",
                "-c", "user.email=fixture@example.invalid", "commit", "-qm", "initial")
        result = invoke()
        assert "0 existing, 1 cloned, 0 skipped, 0 failed" in result.stdout
        assert "0 links existing, 1 links created" in result.stdout
        checkout = root / "apps/selected"
        assert (checkout / "tracked").read_text() == "original\n"
        assert os.readlink(root / "aliases/selected") == "../canonical"
        assert not (root / "apps/excluded").exists()
        assert not (root / "aliases/excluded").exists()

        (checkout / "tracked").write_text("local edit\n")
        result = invoke()
        assert "1 existing, 0 cloned, 0 skipped, 0 failed" in result.stdout
        assert "1 links existing, 0 links created" in result.stdout
        assert (checkout / "tracked").read_text() == "local edit\n"
        assert "1 existing, 0 missing, 0 skipped" in invoke("--status").stdout

        # Directory activation must retain conflicts, continue and return 1.
        shutil.rmtree(root / "apps")
        (root / "apps").write_text("preserve first conflict\n")
        shutil.rmtree(root / "scratch")
        (root / "scratch").write_text("preserve\n")
        shutil.rmtree(root / "canonical")
        conflict = invoke("--directories", code=1)
        assert "directory conflicts or failures" in conflict.stderr
        assert (root / "canonical").is_dir()
        assert (root / "scratch").read_text() == "preserve\n"
        assert (root / "apps").read_text() == "preserve first conflict\n"
        print("Workspace consumer manifest, wrapper and activation checks passed")
    finally:
        shutil.rmtree(fixture)


if __name__ == "__main__":
    main()
