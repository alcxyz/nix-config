#!/usr/bin/env python3
"""Update flake inputs, build the fleet, and commit flake.lock only when green (ADR-0107).

Usage: update.py [NAME...]
       update.py --list [NAME...]

With no NAME every input is updated. A NAME is a group (see GROUPS) or a flake
input name, such as `nixpkgs` or `dms-plugins/aiusage`, mixed freely. After the
lock changes, `nix flake check --no-build` and `deploy --build-only --all` must
pass before flake.lock is committed; otherwise it stays modified and
uncommitted. Nothing is pushed or activated. `--list` prints the inputs the
names resolve to and changes nothing.
"""

from __future__ import annotations

import datetime
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


# Group names must never be flake input names; a test checks both lists.
# Released platform tools on `main` (ADR-0086).
TOOLS = [
    "paperless-tools",
    "regnskap",
    "reportcraft",
    "stashdb-pop",
    "t3rry",
    "hedgedoc",
    "devstats",
]
# Dev builds of released tools on `dev` (ADR-0087).
DEV_TOOLS = ["paperless-tools-dev", "regnskap-dev", "t3rry-dev"]
# The DMS bundle, DankSession and the maintained plugins (ADR-0069). Nested
# overrides need explicit updates even when the bundle has not changed.
DMS = [
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
# `work`, `teams-chat` and `portal-receipts` follow `dev` and are in both app
# groups (ADR-0089).
SHARED_APPS = ["work", "teams-chat", "portal-receipts"]
# Released apps on `main` (ADR-0089).
APPS = ["grove", "canopy", "bivrost", *SHARED_APPS]
# Maintained apps' dev builds on `dev` (ADR-0069, ADR-0089).
DEV_APPS = [
    *DMS,
    "paperflow",
    "grove-dev",
    "canopy-dev",
    "bivrost-dev",
    "paw",
    "vidown",
    *SHARED_APPS,
]

GROUPS = {
    "apps": APPS,
    "dev-apps": DEV_APPS,
    "tools": TOOLS,
    "dev-tools": DEV_TOOLS,
    "dms": DMS,
}

UNDO = "git checkout flake.lock"


class UsageError(Exception):
    pass


def say(message: str) -> None:
    print(f"update: {message}", file=sys.stderr, flush=True)


def load_lock(path: Path) -> dict:
    return json.loads(path.read_text())


def root_inputs(lock: dict) -> dict:
    return lock["nodes"][lock.get("root", "root")].get("inputs", {})


def resolve_node(lock: dict, path: list[str]) -> str | None:
    """Return the lock node an input path names, following `follows` paths."""
    node = lock.get("root", "root")
    for name in path:
        inputs = lock["nodes"].get(node, {}).get("inputs", {})
        if name not in inputs:
            return None
        target = inputs[name]
        if isinstance(target, list):
            resolved = resolve_node(lock, target)
            if resolved is None:
                return None
            node = resolved
        else:
            node = target
    return node


def resolve_names(names: list[str], lock_path: Path) -> list[str]:
    """Expand groups and check input names; an empty list means every input."""
    lock = None
    inputs: list[str] = []
    for name in names:
        if name in GROUPS:
            candidates = GROUPS[name]
        else:
            if lock is None:
                lock = load_lock(lock_path)
            if resolve_node(lock, name.split("/")) is None:
                raise UsageError(
                    f"unknown group or input '{name}'; groups: {', '.join(GROUPS)}; "
                    "inputs are the names in flake.lock (for example nixpkgs or dms-plugins/aiusage)"
                )
            candidates = [name]
        for candidate in candidates:
            if candidate not in inputs:
                inputs.append(candidate)
    return inputs


def input_paths(lock: dict) -> dict[str, str]:
    """Map each input path that owns its node (not a `follows`) to that node."""
    paths: dict[str, str] = {}

    def walk(node: str, prefix: list[str], seen: set[str]) -> None:
        for name, target in sorted(lock["nodes"].get(node, {}).get("inputs", {}).items()):
            if isinstance(target, list) or target in seen:
                continue
            path = [*prefix, name]
            paths["/".join(path)] = target
            walk(target, path, seen | {target})

    walk(lock.get("root", "root"), [], set())
    return paths


def describe(node: dict) -> str:
    locked = node.get("locked", {})
    revision = locked.get("rev") or locked.get("narHash", "?").split("-", 1)[-1]
    text = revision[:7]
    if "lastModified" in locked:
        day = datetime.datetime.fromtimestamp(locked["lastModified"], datetime.timezone.utc)
        text += f" ({day:%Y-%m-%d})"
    return text


def changed_inputs(before: dict, after: dict) -> list[str]:
    old_paths, new_paths = input_paths(before), input_paths(after)
    lines = []
    for path in sorted(set(old_paths) | set(new_paths)):
        old = before["nodes"].get(old_paths.get(path, ""))
        new = after["nodes"].get(new_paths.get(path, ""))
        if old is None and new is not None:
            lines.append(f"- {path}: added {describe(new)}")
        elif new is None and old is not None:
            lines.append(f"- {path}: removed (was {describe(old)})")
        elif old is not None and new is not None and old.get("locked") != new.get("locked"):
            lines.append(f"- {path}: {describe(old)} -> {describe(new)}")
    return lines


def git(*arguments: str, check: bool = True, **options) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *arguments], check=check, text=True, **options)


def failed_targets(report_path: Path) -> list[str]:
    try:
        report = json.loads(report_path.read_text())
    except (OSError, ValueError):
        return []
    targets = []
    for host in report.get("hosts") or []:
        for phase, label in (("system", "system"), ("homeManager", "home-manager")):
            if (host.get(phase) or {}).get("status") == "failed":
                targets.append(f"{host.get('host', '?')} {label}")
    return targets


def red(step: str, targets: list[str] | None = None) -> int:
    say(f"{step} failed; flake.lock is left modified and uncommitted.")
    if targets:
        say("failed targets: " + ", ".join(targets))
    if step.startswith("deploy"):
        say("deploy printed the path of its run record above ('deploy: run record: ...').")
    say(f"undo the update with: {UNDO}")
    return 1


def update(names: list[str]) -> int:
    top = git("rev-parse", "--show-toplevel", capture_output=True).stdout.strip()
    os.chdir(top)
    lock_path = Path("flake.lock")
    inputs = resolve_names(names, lock_path)

    if git("diff", "--quiet", "--", "flake.lock", check=False).returncode != 0:
        say(f"flake.lock already has uncommitted changes; commit or undo them first ({UNDO}).")
        return 1
    # The build sees the working tree but the commit holds only flake.lock, so
    # any other tracked change would make the build test what is not committed.
    dirty = git("status", "--porcelain", "--untracked-files=no", capture_output=True).stdout
    if dirty.strip():
        say("tracked files have uncommitted changes; commit or undo them first, so the build tests exactly what is committed:")
        say(dirty.rstrip())
        return 1

    before_text = lock_path.read_text()
    say("nix flake update " + (" ".join(inputs) if inputs else "(every input)"))
    if subprocess.run(["nix", "flake", "update", *inputs]).returncode != 0:
        if lock_path.read_text() == before_text:
            say("nix flake update failed; flake.lock is unchanged.")
            return 1
        return red("nix flake update")
    after_text = lock_path.read_text()
    if after_text == before_text:
        say("flake.lock did not change; nothing to build or commit.")
        return 0
    changes = changed_inputs(json.loads(before_text), json.loads(after_text))

    say("nix flake check --no-build")
    if subprocess.run(["nix", "flake", "check", "--no-build"]).returncode != 0:
        return red("nix flake check --no-build")

    say("deploy --build-only --all")
    with tempfile.TemporaryDirectory(prefix="nix-config-update-") as work:
        report = Path(work) / "report.json"
        status = subprocess.run(["deploy", "--build-only", "--all", "--json", str(report)]).returncode
        if status != 0:
            return red("deploy --build-only --all", failed_targets(report))

    if lock_path.read_text() != after_text:
        say("flake.lock changed during the build, so the build did not test it; not committing it.")
        say(f"undo the update with: {UNDO}")
        return 1

    subject = "chore(flake): update " + (", ".join(names) if names else "all inputs")
    body = "Built with nix flake check --no-build and deploy --build-only --all.\n\n"
    body += "\n".join(changes) if changes else "The lock changed without a changed input revision."
    commit = git("commit", "--quiet", "--file", "-", "--", "flake.lock", input=f"{subject}\n\n{body}\n", check=False)
    if commit.returncode != 0:
        return red("git commit")
    revision = git("rev-parse", "--short", "HEAD", capture_output=True).stdout.strip()
    say(f"committed {revision} ({subject}); not pushed.")
    return 0


def main(arguments: list[str]) -> int:
    list_only = False
    names = []
    for argument in arguments:
        if argument == "--list":
            list_only = True
        elif argument in ("-h", "--help"):
            print(__doc__.strip())
            return 0
        elif argument.startswith("-"):
            print(f"update: unknown option '{argument}'\n\n{__doc__.strip()}", file=sys.stderr)
            return 2
        else:
            names.append(argument)
    try:
        if list_only:
            inputs = resolve_names(names, Path("flake.lock"))
            if not names:
                inputs = list(root_inputs(load_lock(Path("flake.lock"))))
            print("\n".join(inputs))
            return 0
        return update(names)
    except UsageError as error:
        say(str(error))
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
