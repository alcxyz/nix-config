#!/usr/bin/env python3
"""Merge managed MCP servers into Claude Code's user config (ADR-0081).

Usage: claude-mcp.py <claude.json> <state.json> <servers.json>

servers.json maps each server name to its `mcpServers` entry. Claude Code keeps
user-scoped MCP servers in ~/.claude.json, which it also rewrites with its own
state, so only the entries this script manages are touched, and the file is
replaced only if Claude did not change it meanwhile. The state file records
which servers it manages, so a dropped server is removed while servers the user
added stay, including a hand-made entry that shares a managed name (it is left
unmanaged with a warning).
"""

import copy
import json
import os
import sys
import tempfile


class ChangedError(Exception):
    """The file changed between reading and replacing it."""


def fail(path, message):
    print(f"Cannot update Claude MCP servers in {path}: {message}; existing config was preserved.", file=sys.stderr)
    sys.exit(1)


def load_managed(state_path):
    try:
        with open(state_path, encoding="utf-8") as handle:
            names = json.load(handle).get("managed", [])
    except FileNotFoundError:
        return set()
    except (OSError, ValueError, AttributeError) as error:
        print(f"Warning: cannot read {state_path} ({error}); earlier managed servers are not cleaned up.", file=sys.stderr)
        return set()
    if not isinstance(names, list):
        print(f"Warning: {state_path} has no name list; earlier managed servers are not cleaned up.", file=sys.stderr)
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


def merge_once(config_path, state_path, servers, managed):
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
        original = json.loads(text) if text.strip() else {}
    except ValueError as error:
        fail(config_path, f"invalid JSON ({error})")
    if not isinstance(original, dict):
        fail(config_path, "expected one JSON object")
    document = copy.deepcopy(original)
    entries = document.get("mcpServers", {})
    if not isinstance(entries, dict):
        fail(config_path, "`mcpServers` is not an object")

    names = {
        name for name in servers
        if name in managed or name not in entries or entries[name] == servers[name]
    }
    for name in sorted(set(servers) - names):
        print(f"Warning: {config_path} already has its own MCP server {name!r}; leaving it unmanaged.", file=sys.stderr)
    for name in managed - set(servers):
        entries.pop(name, None)
    for name in sorted(names):
        entries[name] = servers[name]
    if entries:
        document["mcpServers"] = entries
    else:
        document.pop("mcpServers", None)

    rendered = json.dumps(document, indent=2, ensure_ascii=False) + "\n"
    try:
        if document != original:
            write_atomic(config_path, rendered, mode, expected=text)
        write_atomic(state_path, json.dumps({"managed": sorted(names)}, indent=2) + "\n", 0o644)
    except OSError as error:
        fail(config_path, str(error))


def main(config_path, state_path, servers_path):
    with open(servers_path, encoding="utf-8") as handle:
        servers = json.load(handle)
    managed = load_managed(state_path)
    if not servers and not managed:
        return
    for _ in range(3):
        try:
            return merge_once(config_path, state_path, servers, managed)
        except ChangedError:
            continue
    fail(config_path, "Claude Code kept changing it during the update")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    main(*sys.argv[1:])
