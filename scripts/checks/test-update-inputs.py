"""Hermetic contracts for the update entry point, its groups and the inputs they name (ADR-0069, ADR-0080, ADR-0086, ADR-0087, ADR-0089, ADR-0107)."""

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
UPDATE = ROOT / "scripts/update-inputs/update.py"
UPDATE_DMS = ROOT / "scripts/update-inputs/update-dms-plugins.sh"

TOOL_INPUTS = ["paperless-tools", "regnskap", "reportcraft", "stashdb-pop", "t3rry", "hedgedoc", "devstats"]
# Tools whose canonical repository is on GitHub rather than Forgejo.
GITHUB_TOOLS = {"t3rry"}
# Forgejo tools fetched over HTTPS rather than SSH.
FORGEJO_HTTPS_TOOLS = {"devstats"}
# Each dev input is the same repository as a released tool input, on `dev`.
DEV_TOOL_INPUTS = {
    "paperless-tools-dev": "paperless-tools",
    "regnskap-dev": "regnskap",
    "t3rry-dev": "t3rry",
}
APP_INPUTS = ["grove", "canopy", "bivrost"]
# Inputs both app groups refresh (ADR-0089), by input and repository name.
# They follow `dev` on Forgejo.
SHARED_INPUTS = {"work": "bn-bootstrap", "teams-chat": "teams-chat", "portal-receipts": "portal-receipts"}
# Dev builds of released apps, in the dev-apps group.
DEV_APP_INPUTS = {"grove-dev": "grove", "canopy-dev": "canopy", "bivrost-dev": "bivrost"}
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
DEV_APPS_REST = ["paperflow", "grove-dev", "canopy-dev", "bivrost-dev", "paw", "vidown", "work", "teams-chat", "portal-receipts"]
GROUPS = {
    "apps": APP_INPUTS + list(SHARED_INPUTS),
    "dev-apps": DMS_INPUTS + DEV_APPS_REST,
    "tools": TOOL_INPUTS,
    "dev-tools": list(DEV_TOOL_INPUTS),
    "dms": DMS_INPUTS,
}

DEV_URLS = {
    "paperflow": "github:alcxyz/paperflow/dev",
    "grove-dev": "github:alcxyz/grove/dev",
    "canopy-dev": "github:alcxyz/canopy/dev",
    "paw": "github:alcxyz/paw/dev",
    "bivrost-dev": "github:alcxyz/bivrost/dev",
    "vidown": "git+ssh://git@git-ssh.alc.xyz/alcxyz/vidown.git?ref=dev",
    "work": "git+ssh://git@git-ssh.alc.xyz/alcxyz/bn-bootstrap.git?ref=dev",
    "teams-chat": "git+ssh://git@git-ssh.alc.xyz/alcxyz/teams-chat.git?ref=dev",
    "portal-receipts": "git+ssh://git@git-ssh.alc.xyz/alcxyz/portal-receipts.git?ref=dev",
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

# Third-party plugins the bundle takes from their upstream repositories at exact
# revisions (dms-plugins ADR-004), never from a moving branch.
UPSTREAM_PINNED_INPUTS = {
    "worldclock": "WorldClock",
    "calculator": "DankCalculator",
    "screenshot": "DMS-Screenshot",
}

# Owner inputs in no fixed group: `own` adds them to the groups' members.
OWN_ONLY_INPUTS = ["nix-packages", "nix-secrets", "pandora"]

OLD_COMMANDS = ["apps-update", "dev-apps-update", "dms-update", "qa-update", "qaup", "tools-update", "dev-tools-update"]


def list_inputs(*names: str, cwd: Path = ROOT) -> list[str]:
    return subprocess.run(
        ["python3", UPDATE, "--list", *names], cwd=cwd, text=True, capture_output=True, check=True
    ).stdout.splitlines()


def lock_root_inputs() -> dict:
    lock = json.loads((ROOT / "flake.lock").read_text())
    return lock["nodes"][lock["root"]]["inputs"]


class GroupContracts(unittest.TestCase):
    def test_group_lists_are_exact(self):
        for group, inputs in GROUPS.items():
            with self.subTest(group=group):
                self.assertEqual(list_inputs(group), inputs)

    def test_no_group_name_is_an_input_name(self):
        lock = json.loads((ROOT / "flake.lock").read_text())
        names = set()
        for node in lock["nodes"].values():
            names.update(node.get("inputs", {}))
        self.assertFalse((set(GROUPS) | {"own"}) & names)

    def test_groups_name_real_inputs(self):
        # --list checks a plain input name against flake.lock, so listing every
        # group member by name proves each one is a real (possibly nested) input.
        members = sorted({name for inputs in GROUPS.values() for name in inputs})
        self.assertEqual(sorted(list_inputs(*members)), members)

    def test_no_argument_lists_every_input(self):
        self.assertEqual(list_inputs(), list(lock_root_inputs()))

    def test_groups_and_inputs_mix_without_duplicates(self):
        self.assertEqual(list_inputs("dms", "nixpkgs", "dms-plugins"), DMS_INPUTS + ["nixpkgs"])

    def test_unknown_name_is_rejected(self):
        result = subprocess.run(
            ["python3", UPDATE, "--list", "no-such-input"], cwd=ROOT, text=True, capture_output=True
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown group or input 'no-such-input'", result.stderr)
        self.assertIn("apps, dev-apps, tools, dev-tools, dms, own", result.stderr)

    def test_own_is_every_group_and_the_owner_only_inputs(self):
        own = list_inputs("own")
        self.assertEqual(len(own), len(set(own)))
        members = {name for inputs in GROUPS.values() for name in inputs}
        self.assertEqual(set(own), members | set(OWN_ONLY_INPUTS))
        for third_party in ("nixpkgs", "home-manager", "dankMaterialShell", "dms-plugins/worldclock"):
            self.assertNotIn(third_party, own)

    def test_dev_tools_pair_with_released_tools(self):
        self.assertLessEqual(set(DEV_TOOL_INPUTS.values()), set(TOOL_INPUTS))

    def test_dev_apps_pair_with_released_apps(self):
        self.assertLessEqual(set(DEV_APP_INPUTS.values()), set(APP_INPUTS))
        self.assertLessEqual(set(DEV_APP_INPUTS), set(GROUPS["dev-apps"]))

    def test_groups_overlap_only_in_shared_inputs_and_dms(self):
        # dms is the DMS part of dev-apps; the other groups overlap only in
        # the shared app inputs.
        lists = [set(GROUPS[g]) - set(SHARED_INPUTS) for g in ("apps", "dev-apps", "tools", "dev-tools")]
        for i, first in enumerate(lists):
            for second in lists[i + 1 :]:
                self.assertFalse(first & second)
        self.assertEqual(GROUPS["dev-apps"][: len(DMS_INPUTS)], DMS_INPUTS)

    def test_shared_inputs_are_in_both_app_groups_and_follow_dev(self):
        for name, repository in SHARED_INPUTS.items():
            with self.subTest(input=name):
                self.assertIn(name, GROUPS["apps"])
                self.assertIn(name, GROUPS["dev-apps"])
                self.assert_follows(name, repository, "dev")

    def test_old_commands_are_gone(self):
        common = (ROOT / "users/alc/common.nix").read_text()
        justfile = (ROOT / "justfile").read_text()
        for command in OLD_COMMANDS:
            with self.subTest(command=command):
                self.assertNotRegex(common, rf"(?m)^\s*{re.escape(command)}\s*=")
                self.assertNotRegex(justfile, rf"(?m)^{re.escape(command)}\b.*:")
        self.assertRegex(justfile, r"(?m)^update \*NAMES:\n\s+python3 scripts/update-inputs/update\.py \{\{NAMES\}\}$")

    def assert_follows(self, name, repository, ref, https=False):
        flake = (ROOT / "flake.nix").read_text()
        lock = json.loads((ROOT / "flake.lock").read_text())
        node = lock["nodes"][lock_root_inputs()[name]]
        host = r"git\+https://git\.alc\.xyz" if https else r"git\+ssh://git@git-ssh\.alc\.xyz"
        self.assertRegex(
            flake,
            rf'(?m)^\s*{re.escape(name)} = \{{\n\s*url = "{host}/alcxyz/{re.escape(repository)}\.git\?ref={ref}";$',
        )
        self.assertEqual(node["original"]["ref"], ref)

    def assert_github_follows(self, name, repository, ref):
        flake = (ROOT / "flake.nix").read_text()
        lock = json.loads((ROOT / "flake.lock").read_text())
        node = lock["nodes"][lock_root_inputs()[name]]
        self.assertRegex(
            flake,
            rf'(?m)^\s*{re.escape(name)} = \{{\n\s*url = "github:alcxyz/{re.escape(repository)}/{ref}";$',
        )
        self.assertEqual(node["original"]["ref"], ref)

    def assert_tool_follows(self, name, repository, ref):
        if repository in GITHUB_TOOLS:
            self.assert_github_follows(name, repository, ref)
        else:
            self.assert_follows(name, repository, ref, https=repository in FORGEJO_HTTPS_TOOLS)

    def test_each_tool_follows_main(self):
        for name in TOOL_INPUTS:
            with self.subTest(input=name):
                self.assert_tool_follows(name, name, "main")

    def test_each_dev_tool_follows_dev(self):
        for name, repository in DEV_TOOL_INPUTS.items():
            with self.subTest(input=name):
                self.assert_tool_follows(name, repository, "dev")

    def test_each_app_follows_main(self):
        for name in APP_INPUTS:
            with self.subTest(input=name):
                self.assert_github_follows(name, name, "main")

    def test_each_dev_app_follows_dev(self):
        for name, repository in DEV_APP_INPUTS.items():
            with self.subTest(input=name):
                self.assert_github_follows(name, repository, "dev")

    def test_flake_uses_explicit_dev_urls_and_danksession_follow(self):
        flake = (ROOT / "flake.nix").read_text()
        for name, url in DEV_URLS.items():
            with self.subTest(input=name):
                self.assertIn(f'url = "{url}";', flake)
        self.assertIn('danksession.follows = "danksession";', flake)
        self.assertNotIn('danksession.url = "github:alcxyz/DankSession/dev";', flake)

    def test_upstream_plugins_stay_pinned_and_are_not_overridden(self):
        flake = (ROOT / "flake.nix").read_text()
        lock = json.loads((ROOT / "flake.lock").read_text())
        listed = {name for inputs in GROUPS.values() for name in inputs}
        for name, repo in UPSTREAM_PINNED_INPUTS.items():
            with self.subTest(input=name):
                self.assertNotIn(f"dms-plugins/{name}", listed)
                self.assertNotIn(f'{name}.url = "github:alcxyz/{repo}/dev";', flake)
                node = lock["nodes"][name]
                original = node["original"]
                self.assertEqual(original["repo"], repo)
                self.assertNotEqual(original["owner"], "alcxyz")
                self.assertNotIn("ref", original)
                self.assertRegex(original.get("rev", ""), r"^[0-9a-f]{40}$")
                self.assertEqual(original["rev"], node["locked"]["rev"])

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


def stub(path: Path, body: str) -> None:
    bash = shutil.which("bash")
    assert bash is not None
    path.write_text(f"#!{bash}\nset -euo pipefail\n" + textwrap.dedent(body))
    path.chmod(0o755)


INITIAL_LOCK = {
    "nodes": {
        "root": {"inputs": {"nixpkgs": "nixpkgs", "grove": "grove", "work": "work"}},
        "nixpkgs": {"locked": {"rev": "a" * 40, "lastModified": 1762300800}},
        "grove": {"inputs": {"nixpkgs": ["nixpkgs"]}, "locked": {"rev": "b" * 40}},
        "work": {"locked": {"rev": "c" * 40}},
    },
    "root": "root",
    "version": 7,
}


class UpdateRepoCase(unittest.TestCase):
    """Runs update.py in a scratch Git repository with nix and deploy stubbed."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        work = Path(self.temporary.name)
        self.repo = work / "repo"
        self.repo.mkdir()
        self.calls = work / "calls"
        bin_dir = work / "bin"
        bin_dir.mkdir()
        # The update stub moves nixpkgs to a new revision unless told not to.
        stub(
            bin_dir / "nix",
            """\
            printf 'nix %s\\n' "$*" >> "$FAKE_CALLS"
            case "$*" in
              "flake update"*)
                if [[ ${FAKE_LOCK:-change} == change ]]; then
                  python3 - "$@" <<'PY'
            import json
            import sys
            lock = json.load(open("flake.lock"))
            lock["nodes"]["nixpkgs"]["locked"] = {"rev": "d" * 40, "lastModified": 1762473600}
            # A full update moves nix-packages to the newest dev, as Nix does,
            # unless an override pins it.
            arguments = sys.argv[1:]
            if "--override-input" in arguments:
                url = arguments[arguments.index("--override-input") + 2]
                lock["nodes"]["nix-packages"]["locked"]["rev"] = url.split("rev=")[1]
            elif "nix-packages" in lock["nodes"] and len(arguments) == 2:
                lock["nodes"]["nix-packages"]["locked"]["rev"] = "e" * 40
            json.dump(lock, open("flake.lock", "w"))
            PY
                fi
                ;;
              "flake check --no-build")
                [[ ${FAKE_CHECK_FAIL:-0} != 1 ]]
                checks=$(( $(cat "$FAKE_CALLS.checks" 2>/dev/null || echo 0) + 1 ))
                echo "$checks" > "$FAKE_CALLS.checks"
                if (( checks <= ${FAKE_CHECK_INVALID:-0} )); then
                  echo "… while checking the derivation 'checks.x86_64-linux.demo'" >&2
                  echo "error: path '/nix/store/0000000000000000000000000000000a-demo.drv' is not valid" >&2
                  exit 1
                fi
                ;;
              "eval --raw .#"*) ;;
              "flake metadata --json "*) printf '{"locked":{"revCount":%s}}\\n' "${FAKE_PROMOTED_COUNT:-20}" ;;
              "flake lock --override-input nix-packages "*)
                python3 - "$5" <<'PY'
            import json, sys
            lock = json.load(open("flake.lock"))
            node = lock["nodes"]["nix-packages"]["locked"]
            node["rev"] = sys.argv[1].split("rev=")[1]
            json.dump(lock, open("flake.lock", "w"))
            PY
                ;;
              *) echo "unexpected nix invocation: $*" >&2; exit 90 ;;
            esac
            """,
        )
        stub(
            bin_dir / "deploy",
            """\
            printf 'deploy %s\\n' "$*" >> "$FAKE_CALLS"
            [[ $1 == --build-only && $2 == --all && $3 == --json ]]
            if [[ ${FAKE_DEPLOY_FAIL:-0} == 1 ]]; then
              printf '%s\\n' '{"failed":true,"hosts":[{"host":"xyz","system":{"status":"built"},"homeManager":{"status":"failed"}},{"host":"xps","system":{"status":"failed"},"homeManager":{"status":"unchanged"}}]}' > "$4"
              echo "deploy: run record: /state/nix-deploy/runs/test" >&2
              exit 1
            fi
            printf '%s\\n' '{"failed":false,"hosts":[]}' > "$4"
            """,
        )
        self.environment = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FAKE_CALLS": str(self.calls),
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
        }
        self.git("init", "--quiet", "--initial-branch=dev")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("config", "commit.gpgsign", "false")
        (self.repo / "flake.lock").write_text(json.dumps(INITIAL_LOCK, indent=2) + "\n")
        (self.repo / "other.txt").write_text("one\n")
        self.git("add", ".")
        self.git("commit", "--quiet", "-m", "initial")

    def git(self, *arguments: str) -> str:
        return subprocess.run(
            ["git", *arguments], cwd=self.repo, env=self.environment, text=True, capture_output=True, check=True
        ).stdout

    def run_update(self, *arguments: str, **environment: str):
        return subprocess.run(
            ["python3", UPDATE, *arguments],
            cwd=self.repo,
            env={**self.environment, **environment},
            text=True,
            capture_output=True,
        )

    def calls_made(self) -> list[str]:
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def commit_count(self) -> int:
        return int(self.git("rev-list", "--count", "HEAD"))

    def assert_left_uncommitted(self, result):
        self.assertEqual(result.returncode, 1)
        self.assertEqual(self.commit_count(), 1)
        self.assertEqual(self.git("status", "--porcelain"), " M flake.lock\n")
        self.assertIn("flake.lock is left modified and uncommitted", result.stderr)
        self.assertIn("git checkout flake.lock", result.stderr)


class EntryPointTests(UpdateRepoCase):

    def test_green_path_commits_only_flake_lock(self):
        # Untracked files are outside a Git flake, so they do not block.
        (self.repo / "untracked.txt").write_text("not in the flake\n")
        result = self.run_update("apps", "nixpkgs")
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls_made()
        self.assertEqual(calls[0], "nix flake update " + " ".join(GROUPS["apps"] + ["nixpkgs"]))
        self.assertEqual(calls[1], "nix flake check --no-build")
        self.assertRegex(calls[2], r"^deploy --build-only --all --json \S+$")
        self.assertEqual(self.commit_count(), 2)
        self.assertEqual(self.git("show", "--name-only", "--format=", "HEAD").split(), ["flake.lock"])
        message = self.git("log", "-1", "--format=%B")
        self.assertTrue(message.startswith("chore(flake): update apps, nixpkgs\n\n"))
        self.assertIn("- nixpkgs: aaaaaaa (2025-11-05) -> ddddddd (2025-11-07)", message)
        self.assertNotIn("grove", message)
        self.assertNotIn("Co-authored-by", message)
        self.assertEqual(self.git("status", "--porcelain"), "?? untracked.txt\n")

    def test_no_argument_updates_every_input(self):
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls_made()[0], "nix flake update")
        self.assertTrue(self.git("log", "-1", "--format=%s").startswith("chore(flake): update all inputs"))

    def test_unknown_name_runs_nothing(self):
        result = self.run_update("tools", "no-such-input")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown group or input 'no-such-input'", result.stderr)
        self.assertEqual(self.calls_made(), [])

    def test_nested_input_name_is_accepted(self):
        result = self.run_update("--list", "grove/nixpkgs")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.split(), ["grove/nixpkgs"])

    def test_refuses_a_modified_lock(self):
        (self.repo / "flake.lock").write_text(json.dumps(INITIAL_LOCK) + "\n")
        result = self.run_update("nixpkgs")
        self.assertEqual(result.returncode, 1)
        self.assertIn("flake.lock already has uncommitted changes", result.stderr)
        self.assertEqual(self.calls_made(), [])
        self.assertEqual(self.commit_count(), 1)

    def test_refuses_staged_changes(self):
        (self.repo / "other.txt").write_text("staged\n")
        self.git("add", "other.txt")
        result = self.run_update("nixpkgs")
        self.assertEqual(result.returncode, 1)
        self.assertIn("tracked files have uncommitted changes", result.stderr)
        self.assertEqual(self.calls_made(), [])

    def test_refuses_unstaged_tracked_changes(self):
        # The build would include this edit, but the commit would not.
        (self.repo / "other.txt").write_text("unstaged edit\n")
        result = self.run_update("nixpkgs")
        self.assertEqual(result.returncode, 1)
        self.assertIn("tracked files have uncommitted changes", result.stderr)
        self.assertEqual(self.calls_made(), [])
        self.assertEqual(self.commit_count(), 1)

    def test_unchanged_lock_exits_cleanly(self):
        result = self.run_update("nixpkgs", FAKE_LOCK="same")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("flake.lock did not change", result.stderr)
        self.assertEqual(self.calls_made(), ["nix flake update nixpkgs"])
        self.assertEqual(self.commit_count(), 1)

    def test_failed_check_leaves_the_lock_uncommitted(self):
        result = self.run_update("nixpkgs", FAKE_CHECK_FAIL="1")
        self.assert_left_uncommitted(result)
        self.assertIn("nix flake check --no-build failed", result.stderr)
        self.assertEqual(len(self.calls_made()), 2)

    def test_invalid_derivation_is_instantiated_and_checked_again(self):
        result = self.run_update("nixpkgs", FAKE_CHECK_INVALID="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.calls_made()[1:4],
            ["nix flake check --no-build", "nix eval --raw .#checks.x86_64-linux.demo.drvPath", "nix flake check --no-build"],
        )
        self.assertEqual(self.commit_count(), 2)

    def test_invalid_derivation_gives_up_after_three_checks(self):
        result = self.run_update("nixpkgs", FAKE_CHECK_INVALID="9")
        self.assert_left_uncommitted(result)
        self.assertEqual(self.calls_made().count("nix flake check --no-build"), 3)
        self.assertNotIn("deploy", "\n".join(self.calls_made()))

    def test_failed_build_names_targets_and_leaves_the_lock_uncommitted(self):
        result = self.run_update("nixpkgs", FAKE_DEPLOY_FAIL="1")
        self.assert_left_uncommitted(result)
        self.assertIn("deploy --build-only --all failed", result.stderr)
        self.assertIn("failed targets: xyz home-manager, xps system", result.stderr)
        self.assertIn("deploy: run record: /state/nix-deploy/runs/test", result.stderr)


class PackagesLockTests(UpdateRepoCase):
    """nix-packages follows its validated `promoted` branch, never the newest dev (ADR-0080)."""

    def make_packages(self, url: str | None = None) -> None:
        source = Path(self.temporary.name) / "nix-packages"
        source.mkdir()

        def run(*arguments: str) -> str:
            return subprocess.run(
                ["git", "-c", "user.name=T", "-c", "user.email=t@example.invalid", *arguments],
                cwd=source, env=self.environment, check=True, capture_output=True, text=True,
            ).stdout.strip()

        run("init", "--quiet", "--initial-branch=dev")
        run("commit", "--quiet", "--allow-empty", "-m", "one")
        self.locked = run("rev-parse", "HEAD")
        run("commit", "--quiet", "--allow-empty", "-m", "two")
        self.promoted = run("rev-parse", "HEAD")
        run("branch", "promoted")
        lock = json.loads((self.repo / "flake.lock").read_text())
        lock["nodes"]["root"]["inputs"]["nix-packages"] = "nix-packages"
        lock["nodes"]["nix-packages"] = {
            "locked": {"rev": self.locked, "revCount": 10, "type": "git", "url": url or f"file://{source}", "ref": "dev"},
            "original": {"type": "git", "url": url or f"file://{source}", "ref": "dev"},
        }
        (self.repo / "flake.lock").write_text(json.dumps(lock, indent=2) + "\n")
        self.git("commit", "--quiet", "-am", "add nix-packages")

    def locked_packages(self) -> str:
        return json.loads((self.repo / "flake.lock").read_text())["nodes"]["nix-packages"]["locked"]["rev"]

    def test_every_input_locks_packages_to_promoted_not_dev(self):
        self.make_packages()
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls_made()
        # The update itself pins nix-packages, so Nix never fetches its dev.
        self.assertRegex(calls[1], rf"^nix flake update --override-input nix-packages git\+file://\S+\?ref=dev&rev={self.promoted}$")
        self.assertEqual(self.locked_packages(), self.promoted)
        self.assertIn(f"- nix-packages: {self.locked[:7]} -> {self.promoted[:7]}", self.git("log", "-1", "--format=%B"))

    def test_named_packages_skip_flake_update(self):
        self.make_packages()
        result = self.run_update("nix-packages")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse([call for call in self.calls_made() if call.startswith("nix flake update")])
        self.assertRegex(self.calls_made()[1], rf"^nix flake lock --override-input nix-packages \S+&rev={self.promoted}$")
        self.assertEqual(self.locked_packages(), self.promoted)

    def test_other_names_leave_packages_alone(self):
        self.make_packages()
        result = self.run_update("nixpkgs")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.calls_made()[0], "nix flake update nixpkgs")
        self.assertNotIn("nix-packages", "\n".join(self.calls_made()))
        self.assertEqual(self.locked_packages(), self.locked)

    def assert_keeps_locked(self, promoted_count: str):
        self.make_packages()
        result = self.run_update("nix-packages", "nixpkgs", FAKE_PROMOTED_COUNT=promoted_count)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("is not newer than the locked", result.stderr)
        self.assertEqual(self.locked_packages(), self.locked)

    def test_older_promoted_keeps_the_locked_revision(self):
        self.assert_keeps_locked("5")

    def test_promoted_as_old_keeps_the_locked_revision(self):
        # As lock-promoted-packages.sh: the same count on another line is not newer.
        self.assert_keeps_locked("10")

    def test_lock_without_a_count_keeps_the_locked_revision(self):
        self.make_packages()
        lock = json.loads((self.repo / "flake.lock").read_text())
        del lock["nodes"]["nix-packages"]["locked"]["revCount"]
        (self.repo / "flake.lock").write_text(json.dumps(lock, indent=2) + "\n")
        self.git("commit", "--quiet", "-am", "drop the count")
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("does not record how old", result.stderr)
        self.assertEqual(self.locked_packages(), self.locked)

    def test_unreadable_promoted_keeps_the_locked_revision(self):
        self.make_packages(url=f"file://{self.temporary.name}/missing")
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("could not read nix-packages's promoted branch", result.stderr)
        self.assertEqual(self.locked_packages(), self.locked)


class PathPackagesTests(UpdateRepoCase):
    def test_a_path_input_updates_without_promoted(self):
        lock = json.loads((self.repo / "flake.lock").read_text())
        lock["nodes"]["root"]["inputs"]["nix-packages"] = "nix-packages"
        lock["nodes"]["nix-packages"] = {
            "locked": {"type": "path", "path": "/src/nix-packages", "narHash": "sha256-x"},
            "original": {"type": "path", "path": "/src/nix-packages"},
        }
        (self.repo / "flake.lock").write_text(json.dumps(lock, indent=2) + "\n")
        self.git("commit", "--quiet", "-am", "path nix-packages")
        for names in ((), ("nix-packages", "nixpkgs")):
            with self.subTest(names=names):
                self.calls.unlink(missing_ok=True)
                result = self.run_update(*names)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("nix-packages is not a git input", result.stderr)
                self.assertNotIn("--override-input", "\n".join(self.calls_made()))
                self.assertEqual(self.calls_made()[0], "nix flake update" + "".join(f" {n}" for n in names))
                self.git("reset", "--quiet", "--hard", "HEAD~1")


class DmsUpdaterTests(unittest.TestCase):
    """The scheduled DMS updater takes its list from the dms group (ADR-0069)."""

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.work = Path(self.temporary.name)
        bin_dir = self.work / "bin"
        bin_dir.mkdir()
        self.calls = self.work / "nix-calls"
        self.output = self.work / "github-output"
        stub(
            bin_dir / "nix",
            """\
            printf '%s\\n' "$*" >> "$FAKE_NIX_CALLS"
            case "$*" in
              "flake update"*)
                if [[ "${FAKE_LOCK_MODE:-unchanged}" == nested-change ]]; then
                  printf '%s\\n' '{"nodes":{"dms-plugins":{"locked":{"rev":"bundle-old"}},"aiusage":{"locked":{"rev":"nested-new"}}}}' > flake.lock
                fi
                ;;
              "flake check --no-build") [[ "${FAKE_CHECK_FAIL:-0}" != 1 ]] ;;
              "eval --json "*) printf '%s\\n' '["dankaiusage-1.2.3"]' ;;
              "build "*) [[ "${FAKE_BUILD_FAIL:-0}" != 1 ]] ;;
              *) echo "unexpected nix invocation: $*" >&2; exit 90 ;;
            esac
            """,
        )
        self.environment = {
            **os.environ,
            "PATH": f"{bin_dir}:{os.environ['PATH']}",
            "FAKE_NIX_CALLS": str(self.calls),
            "GITHUB_OUTPUT": str(self.output),
        }
        scripts = self.work / "scripts/update-inputs"
        scripts.mkdir(parents=True)
        shutil.copy2(UPDATE, scripts / UPDATE.name)
        shutil.copy2(UPDATE_DMS, scripts / UPDATE_DMS.name)
        (self.work / "flake.lock").write_text(
            json.dumps(
                {"nodes": {"dms-plugins": {"locked": {"rev": "bundle-old"}}, "aiusage": {"locked": {"rev": "nested-old"}}}}
            )
        )

    def run_script(self, **environment: str):
        return subprocess.run(
            ["bash", UPDATE_DMS],
            cwd=self.work,
            env={**self.environment, **environment},
            text=True,
            capture_output=True,
        )

    def read_calls(self):
        return self.calls.read_text().splitlines() if self.calls.exists() else []

    def test_nested_change_refreshes_when_bundle_revision_is_unchanged(self):
        result = self.run_script(FAKE_LOCK_MODE="nested-change")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.read_calls(),
            [
                "flake update " + " ".join(DMS_INPUTS),
                "flake check --no-build",
                'eval --json .#homeConfigurations.alc-xyz.config.home.packages --apply xs: map (x: x.name or "") xs',
                "build .#homeConfigurations.alc-xyz.activationPackage --no-link",
            ],
        )
        output = self.output.read_text()
        self.assertIn("updated=true", output)
        self.assertIn("revision=bundle-old", output)
        self.assertIn("version=1.2.3", output)

    def test_unchanged_lock_is_a_noop(self):
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_calls(), ["flake update " + " ".join(DMS_INPUTS)])
        self.assertEqual(self.output.read_text(), "updated=false\n")

    def test_validation_failure_does_not_emit_success_outputs(self):
        result = self.run_script(FAKE_LOCK_MODE="nested-change", FAKE_CHECK_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        output = self.output.read_text() if self.output.exists() else ""
        self.assertNotIn("updated=true", output)
        self.assertNotIn("version=", output)
        self.assertNotIn("revision=", output)


if __name__ == "__main__":
    unittest.main()
