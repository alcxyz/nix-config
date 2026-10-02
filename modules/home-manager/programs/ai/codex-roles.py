#!/usr/bin/env python3
"""Merge managed agent role registrations into Codex's user config (ADR-0079).

Usage: codex-roles.py <config.toml> <state.json> <roles.json>

roles.json maps each role name to {"description": ..., "config_file": ...}.
Codex also writes config.toml (for example project trust), so only the
`[agents.<role>]` tables this script manages are touched. The state file
records which roles it manages, so a renamed or dropped role's table is
removed while tables the user added by hand stay, including a hand-made table
that shares a role's name (it is left unmanaged with a warning).
"""

import copy
import json
import os
import sys
import tempfile
import tomllib

import tomlkit


class ChangedError(Exception):
    """The file changed between reading and replacing it."""


def fail(path, message):
    print(f"Cannot update Codex roles in {path}: {message}; existing config was preserved.", file=sys.stderr)
    sys.exit(1)


def load_managed(state_path):
    try:
        with open(state_path, encoding="utf-8") as handle:
            names = json.load(handle).get("managed", [])
    except FileNotFoundError:
        return set()
    except (OSError, ValueError, AttributeError) as error:
        print(f"Warning: cannot read {state_path} ({error}); registrations of earlier roles are not cleaned up.", file=sys.stderr)
        return set()
    if not isinstance(names, list):
        print(f"Warning: {state_path} has no role list; registrations of earlier roles are not cleaned up.", file=sys.stderr)
        return set()
    return {name for name in names if isinstance(name, str)}


def write_atomic(path, text, mode, expected=None):
    """Replace `path` with `text`; with `expected`, only if the file still holds it."""
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    handle, temporary = tempfile.mkstemp(prefix=os.path.basename(path) + ".tmp.", dir=directory)
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.chmod(temporary, mode)
        if expected is not None:
            # Codex writes this file too; never replace a version it saved meanwhile.
            try:
                with open(path, encoding="utf-8") as current:
                    if current.read() != expected:
                        raise ChangedError(path)
            except FileNotFoundError:
                if expected != "":
                    raise ChangedError(path) from None
        os.replace(temporary, path)
    except BaseException:
        if os.path.exists(temporary):
            os.remove(temporary)
        raise


def adopted(original_agents, roles, managed):
    """Role names to write: never take over a hand-made table of the same name."""
    return {
        name for name in roles
        if name in managed or name not in original_agents or original_agents[name] == roles[name]
    }


def expected_result(original, roles, managed, names):
    """The parsed config the merge must produce: only managed roles change."""
    result = copy.deepcopy(original)
    agents = result.setdefault("agents", {})
    for name in managed - set(roles):
        agents.pop(name, None)
    agents.update({name: dict(roles[name]) for name in names})
    if not agents:
        del result["agents"]
    return result


def main(config_path, state_path, roles_path):
    with open(roles_path, encoding="utf-8") as handle:
        roles = json.load(handle)
    managed = load_managed(state_path)
    if not roles and not managed:
        return  # Nothing to register or clean up; leave the config alone.
    for _ in range(3):
        try:
            return merge_once(config_path, state_path, roles, managed)
        except ChangedError:
            continue
    fail(config_path, "Codex kept changing it during the update")


def merge_once(config_path, state_path, roles, managed):

    mode = 0o600
    if os.path.islink(config_path):
        fail(config_path, "it is a symbolic link")
    try:
        with open(config_path, encoding="utf-8") as handle:
            text = handle.read()
        mode = os.stat(config_path).st_mode & 0o777
    except FileNotFoundError:
        text = ""
    except OSError as error:
        fail(config_path, str(error))
    try:
        document = tomlkit.parse(text)
    except Exception as error:  # tomlkit raises several parse error types
        fail(config_path, f"invalid TOML ({error})")

    agents = document.get("agents")
    if agents is None:
        agents = tomlkit.table(is_super_table=True)
        document["agents"] = agents
    elif isinstance(agents, tomlkit.items.InlineTable):
        # Standard tables cannot nest inside an inline table, so convert it.
        table = tomlkit.table(is_super_table=True)
        for key, value in agents.items():
            table[key] = value
        document["agents"] = table
        agents = document["agents"]
    elif not isinstance(agents, dict):
        fail(config_path, "`agents` is not a table")

    try:
        original = tomllib.loads(text)
    except tomllib.TOMLDecodeError as error:
        fail(config_path, f"invalid TOML ({error})")
    original_agents = original.get("agents", {}) if isinstance(original.get("agents"), dict) else {}
    names = adopted(original_agents, roles, managed)
    for name in sorted(set(roles) - names):
        print(f"Warning: {config_path} already has its own [agents.{name}]; leaving it unmanaged.", file=sys.stderr)

    for name in sorted(managed - set(roles)):
        if name in agents:
            del agents[name]
    for name in sorted(names):
        table = tomlkit.table()
        table["description"] = roles[name]["description"]
        table["config_file"] = roles[name]["config_file"]
        agents[name] = table
    if len(agents) == 0:
        del document["agents"]

    rendered = tomlkit.dumps(document)
    try:
        merged = tomllib.loads(rendered)
    except tomllib.TOMLDecodeError as error:
        fail(config_path, f"the merged result would be invalid TOML ({error})")
    # Dotted keys and other layouts can make an edit land somewhere else, so
    # compare meanings rather than trusting the edit.
    if merged != expected_result(original, roles, managed, names):
        fail(config_path, "the merge would change unrelated settings; use standard [agents.<name>] tables")
    try:
        if rendered != text:
            write_atomic(config_path, rendered, mode, expected=text)
        write_atomic(state_path, json.dumps({"managed": sorted(names)}, indent=2) + "\n", 0o644)
    except OSError as error:
        fail(config_path, str(error))


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    main(*sys.argv[1:])
