#!/usr/bin/env python3
"""Update flake inputs, build the fleet, and commit flake.lock only when green (ADR-0107).

Usage: update.py [NAME...]
       update.py --list [NAME...]

With no NAME every input is updated. A NAME is a group (see GROUPS, plus
`own`: every input from the owner's repositories) or a flake input name, such
as `nixpkgs` or `dms-plugins/aiusage`, mixed freely. nix-packages is locked to
its validated `promoted` branch rather than the newest `dev` (ADR-0080). After
the lock changes, `nix flake check --no-build` and `deploy --build-only --all`
must pass before flake.lock is committed; otherwise it stays modified and
uncommitted. Nothing is pushed or activated. `--list` prints the inputs the
names resolve to and changes nothing.
"""

from __future__ import annotations

import datetime
import json
import os
from pathlib import Path
import re
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
# `own` is computed from flake.lock, so a new input from the owner's
# repositories joins it without a list to maintain: every top-level input
# fetched from them, plus the nested DMS overrides, which need explicit updates.
OWN = "own"
OWN_SOURCE = re.compile(r"^(?:https|ssh)://(?:git@)?git(?:-ssh)?\.alc\.xyz/alcxyz/")
OWN_GITHUB_OWNER = "alcxyz"

# The package flake is locked to the revision package promotion validated, never
# to the newest `dev` (ADR-0080).
PACKAGES = "nix-packages"
PROMOTED_BRANCH = "promoted"

# `nix flake check` sometimes reports a derivation it has just evaluated as
# "not valid", because the .drv was never written to the store. Instantiating the
# named check on its own writes it, after which the check passes.
INVALID_DRV = re.compile(r"error: path '/nix/store/[^']+\.drv' is not valid")
CHECKED_ATTRIBUTE = re.compile(r"while checking the (derivation|NixOS configuration) '([^']+)'")
CHECK_ATTEMPTS = 3

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


def is_own(node: dict) -> bool:
    original = node.get("original", {})
    if original.get("type") == "github":
        return original.get("owner") == OWN_GITHUB_OWNER
    return original.get("type") == "git" and bool(OWN_SOURCE.match(original.get("url", "")))


def own_inputs(lock: dict) -> list[str]:
    """Every top-level input from the owner's repositories, then the nested DMS overrides."""
    inputs = [
        name
        for name, target in root_inputs(lock).items()
        if not isinstance(target, list) and is_own(lock["nodes"].get(target, {}))
    ]
    inputs += [name for name in DMS if "/" in name and resolve_node(lock, name.split("/")) is not None]
    return inputs


def resolve_names(names: list[str], lock_path: Path) -> list[str]:
    """Expand groups and check input names; an empty list means every input."""
    lock = None
    inputs: list[str] = []
    for name in names:
        if name in GROUPS:
            candidates = GROUPS[name]
        elif name == OWN:
            if lock is None:
                lock = load_lock(lock_path)
            candidates = own_inputs(lock)
        else:
            if lock is None:
                lock = load_lock(lock_path)
            if resolve_node(lock, name.split("/")) is None:
                raise UsageError(
                    f"unknown group or input '{name}'; groups: {', '.join([*GROUPS, OWN])}; "
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


def packages_target(node: dict) -> tuple[str, str]:
    """Return the nix-packages revision to lock and why: `promoted`, or the
    current revision when `promoted` cannot be read or is not newer, as
    lock-promoted-packages.sh decides."""
    original, locked = node["original"], node["locked"]
    current = locked["rev"]
    url = original.get("url", "")
    if not re.match(r"^(https|ssh|file)://", url):
        return current, f"{PACKAGES} has an unsupported URL; keeping {current[:7]}"
    try:
        listing = subprocess.run(
            ["git", "ls-remote", url, f"refs/heads/{PROMOTED_BRANCH}"],
            text=True, capture_output=True, timeout=30, check=True,
        ).stdout.split()
    except (subprocess.SubprocessError, OSError):
        listing = []
    promoted = listing[0] if listing else ""
    if not re.fullmatch(r"[0-9a-f]{40}", promoted):
        return current, f"could not read {PACKAGES}'s {PROMOTED_BRANCH} branch; keeping {current[:7]}"
    if promoted == current:
        return current, f"{PACKAGES} is already at {PROMOTED_BRANCH} {current[:7]}"
    locked_count = locked.get("revCount")
    if not isinstance(locked_count, int):
        return current, f"flake.lock does not record how old {PACKAGES} {current[:7]} is; keeping it"
    metadata = subprocess.run(
        ["nix", "flake", "metadata", "--json", f"git+{url}?ref={original.get('ref', 'HEAD')}&rev={promoted}"],
        text=True, capture_output=True,
    )
    try:
        promoted_count = json.loads(metadata.stdout)["locked"]["revCount"]
    except (ValueError, KeyError, TypeError):
        return current, f"could not tell how old {PROMOTED_BRANCH} {promoted[:7]} is; keeping {current[:7]}"
    if promoted_count <= locked_count:
        return current, f"{PROMOTED_BRANCH} {promoted[:7]} is not newer than the locked {current[:7]}; keeping it"
    return promoted, f"locking {PACKAGES} to {PROMOTED_BRANCH} {promoted[:7]}"


def packages_override(node: dict) -> tuple[list[str], str]:
    """Return the Nix arguments that lock nix-packages to its target revision,
    and that revision. Passing them to the update itself means Nix never
    fetches the unvalidated `dev`."""
    target, reason = packages_target(node)
    say(reason)
    original = node["original"]
    url = f"git+{original['url']}?ref={original.get('ref', 'HEAD')}&rev={target}"
    return ["--override-input", PACKAGES, url], target


def packages_locked(node: dict, target: str, lock_path: Path) -> bool:
    after = load_lock(lock_path)
    after_node = after["nodes"][root_inputs(after)[PACKAGES]]
    # A changed original would make the next evaluation relock from the moving ref.
    return after_node["locked"].get("rev") == target and after_node["original"] == node["original"]


def flake_check() -> bool:
    """Run `nix flake check --no-build`, instantiating a check it reports as not
    valid and trying again, up to CHECK_ATTEMPTS runs."""
    for attempt in range(1, CHECK_ATTEMPTS + 1):
        process = subprocess.Popen(["nix", "flake", "check", "--no-build"], stderr=subprocess.PIPE, text=True)
        assert process.stderr is not None
        output = []
        for line in process.stderr:
            sys.stderr.write(line)
            output.append(line)
        if process.wait() == 0:
            return True
        text = "".join(output)
        checked = CHECKED_ATTRIBUTE.findall(text)
        if not INVALID_DRV.search(text) or not checked or attempt == CHECK_ATTEMPTS:
            return False
        kind, attribute = checked[-1]
        if kind == "NixOS configuration":
            attribute += ".config.system.build.toplevel"
        say(f"nix flake check did not write a derivation of {attribute}; instantiating it and checking again")
        instantiate = subprocess.run(["nix", "eval", "--raw", f".#{attribute}.drvPath"], stdout=subprocess.DEVNULL)
        if instantiate.returncode != 0:
            return False
    return False


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
    before = json.loads(before_text)
    # nix-packages never follows `dev`: when the update covers it, the update
    # itself locks it to `promoted` (or keeps it), so Nix never fetches `dev`.
    packages = PACKAGES in root_inputs(before) and (not inputs or PACKAGES in inputs)
    if packages:
        node = before["nodes"][root_inputs(before)[PACKAGES]]
        # Only a git input has a `promoted` branch to follow; another kind, such
        # as a local path checkout, updates like any other input.
        if node.get("original", {}).get("type") != "git" or node.get("locked", {}).get("type") != "git":
            say(f"{PACKAGES} is not a git input, so it is updated without its {PROMOTED_BRANCH} branch")
            packages = False
    others = [name for name in inputs if name != PACKAGES or not packages]
    override: list[str] = []
    if packages:
        override, target = packages_override(node)
    command = ["update", *others] if others or not inputs else ["lock"]
    say(f"nix flake {command[0]} " + (" ".join(others) if others else "(every input)" if not inputs else PACKAGES))
    if subprocess.run(["nix", "flake", *command, *override]).returncode != 0:
        if lock_path.read_text() == before_text:
            say(f"nix flake {command[0]} failed; flake.lock is unchanged.")
            return 1
        return red(f"nix flake {command[0]}")
    if packages and not packages_locked(node, target, lock_path):
        return red(f"locking {PACKAGES} to {target[:7]}")
    after_text = lock_path.read_text()
    if after_text == before_text:
        say("flake.lock did not change; nothing to build or commit.")
        return 0
    changes = changed_inputs(json.loads(before_text), json.loads(after_text))

    say("nix flake check --no-build")
    if not flake_check():
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
