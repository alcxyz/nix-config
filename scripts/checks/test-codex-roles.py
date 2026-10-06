#!/usr/bin/env python3
"""Contract tests for the Codex agent role merge (ADR-0079)."""

import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile
import tomllib

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "modules/home-manager/programs/ai/codex-roles.py"


def merge(config, state, roles):
    roles_file = config.parent.parent / "roles.json"
    roles_file.write_text(json.dumps(roles))
    return subprocess.run(
        [sys.executable, str(SCRIPT), str(config), str(state), str(roles_file)],
        capture_output=True, text=True,
    )


def role(name):
    return {"description": f"{name} work", "config_file": f"/home/u/.codex/{name}.config.toml"}


with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    config = root / "codex" / "config.toml"
    state = root / "state" / "agent-roles" / "codex-managed.json"

    # Without roles or an existing config, nothing is created.
    result = merge(config, state, {})
    assert result.returncode == 0, result.stderr
    assert not config.exists(), "an empty role set must not create a Codex config"

    # A first run creates private registrations and records what it manages.
    result = merge(config, state, {"light": role("light"), "deep": role("deep")})
    assert result.returncode == 0, result.stderr
    data = tomllib.loads(config.read_text())
    assert data["agents"]["deep"] == role("deep"), data
    assert stat.S_IMODE(config.stat().st_mode) == 0o600, oct(config.stat().st_mode)
    assert json.loads(state.read_text()) == {"managed": ["deep", "light"]}

    # Content Codex or the user wrote is preserved, including formatting.
    existing = config.read_text()
    config.write_text(
        '# user comment\nmodel = "x"\n\n[projects."/src"]\ntrust_level = "trusted"\n\n'
        "[agents]\nmax_threads = 4\n\n[agents.mine]\ndescription = \"hand made\"\n"
        'config_file = "/elsewhere.toml"\n\n' + existing.split("[agents]", 1)[-1].lstrip()
    )
    os.chmod(config, 0o640)
    result = merge(config, state, {"light": {**role("light"), "description": "updated"}})
    assert result.returncode == 0, result.stderr
    text = config.read_text()
    data = tomllib.loads(text)
    assert text.startswith("# user comment\n"), text
    assert data["projects"]["/src"]["trust_level"] == "trusted", data
    assert data["agents"]["max_threads"] == 4, data
    assert data["agents"]["mine"]["description"] == "hand made", data
    assert data["agents"]["light"]["description"] == "updated", data
    # A role it managed before and no longer defines is removed.
    assert "deep" not in data["agents"], data
    assert stat.S_IMODE(config.stat().st_mode) == 0o640, "an existing mode is kept"
    assert json.loads(state.read_text()) == {"managed": ["light"]}

    # A hand-made table that shares a role's name is never taken over.
    result = merge(config, state, {"light": {**role("light"), "description": "updated"}, "mine": role("mine")})
    assert result.returncode == 0 and "leaving it unmanaged" in result.stderr, result
    data = tomllib.loads(config.read_text())
    assert data["agents"]["mine"]["description"] == "hand made", data
    assert json.loads(state.read_text()) == {"managed": ["light"]}

    # Removing every role keeps the user's own agent settings.
    result = merge(config, state, {})
    assert result.returncode == 0, result.stderr
    data = tomllib.loads(config.read_text())
    assert set(data["agents"]) == {"max_threads", "mine"}, data

    # An unchanged result leaves the file untouched.
    before = config.stat().st_mtime_ns
    result = merge(config, state, {})
    assert result.returncode == 0 and config.stat().st_mtime_ns == before

    # Invalid TOML and symbolic links fail without changing anything.
    config.write_text("this is = = not toml\n")
    result = merge(config, state, {"light": role("light")})
    assert result.returncode == 1 and "existing config was preserved" in result.stderr, result
    assert config.read_text() == "this is = = not toml\n"
    target = root / "target.toml"
    target.write_text("")
    config.unlink()
    config.symlink_to(target)
    result = merge(config, state, {"light": role("light")})
    assert result.returncode == 1 and target.read_text() == "", result

    # An inline `agents` table is converted, keeping its settings valid.
    config.unlink()
    config.write_text('model = "x"\nagents = { max_threads = 4 }\n')
    result = merge(config, state, {"deep": role("deep")})
    assert result.returncode == 0, result.stderr
    data = tomllib.loads(config.read_text())
    assert data["agents"]["max_threads"] == 4 and data["agents"]["deep"] == role("deep"), data

    # Without roles and without recorded roles, even an unusable config is left alone.
    pathlib.Path(state).unlink()
    config.write_text("this is = = not toml\n")
    result = merge(config, state, {})
    assert result.returncode == 0 and config.read_text() == "this is = = not toml\n", result
    assert not state.exists(), "nothing to manage writes no state"

    # Dotted keys that an edit could misplace are refused rather than rewritten.
    config.write_text('agents.mine.description = "mine"\nagents.max_threads = 4\n')
    original = config.read_text()
    state.write_text('{"managed": []}')
    result = merge(config, state, {"build": role("build"), "deep": role("deep"), "light": role("light")})
    assert result.returncode == 1 and "unrelated settings" in result.stderr, result
    assert config.read_text() == original, "a refused merge leaves the file unchanged"

    # A non-table `agents` key is refused rather than replaced.
    config.unlink()
    config.write_text('agents = "x"\n')
    result = merge(config, state, {"light": role("light")})
    assert result.returncode == 1 and config.read_text() == 'agents = "x"\n', result

# MCP servers use the same merge for [mcp_servers.<name>], including nested tool tables (ADR-0081).
with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    config = root / "codex" / "config.toml"
    state = root / "state" / "codex-mcp.json"
    config.parent.mkdir()
    config.write_text('[agents.deep]\ndescription = "d"\nconfig_file = "/d.toml"\n\n[mcp_servers.mine]\ncommand = "mine"\n')
    server = {
        "command": "/profile/bin/forgejo-mcp-agent",
        "enabled_tools": ["get_repo", "create_issue"],
        "default_tools_approval_mode": "prompt",
        "tools": {"get_repo": {"approval_mode": "approve"}},
    }
    servers_file = root / "servers.json"

    def merge_servers(servers):
        servers_file.write_text(json.dumps(servers))
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(config), str(state), str(servers_file), "mcp_servers"],
            capture_output=True, text=True,
        )

    result = merge_servers({"forgejo": server})
    assert result.returncode == 0, result.stderr
    data = tomllib.loads(config.read_text())
    assert data["mcp_servers"] == {"mine": {"command": "mine"}, "forgejo": server}, data
    assert data["agents"]["deep"]["description"] == "d", data
    assert json.loads(state.read_text()) == {"managed": ["forgejo"]}
    result = merge_servers({"forgejo": server})
    assert result.returncode == 0 and tomllib.loads(config.read_text())["mcp_servers"]["forgejo"] == server, result
    result = merge_servers({})
    assert result.returncode == 0, result.stderr
    assert tomllib.loads(config.read_text())["mcp_servers"] == {"mine": {"command": "mine"}}

# Top-level settings use `.` and land before the first table (ADR-0084).
with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    config = root / "codex" / "config.toml"
    state = root / "state" / "codex-settings.json"
    config.parent.mkdir()
    config.write_text('model = "x"\n\n[projects."/src"]\ntrust_level = "trusted"\n\n[mcp_servers.mine]\ncommand = "mine"\n')
    settings_file = root / "settings.json"

    def merge_settings(settings):
        settings_file.write_text(json.dumps(settings))
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(config), str(state), str(settings_file), "."],
            capture_output=True, text=True,
        )

    result = merge_settings({"mcp_oauth_credentials_store": "file"})
    assert result.returncode == 0, result.stderr
    data = tomllib.loads(config.read_text())
    assert data["mcp_oauth_credentials_store"] == "file", data
    assert data["model"] == "x" and data["projects"]["/src"]["trust_level"] == "trusted", data
    assert data["mcp_servers"] == {"mine": {"command": "mine"}}, data
    assert json.loads(state.read_text()) == {"managed": ["mcp_oauth_credentials_store"]}
    result = merge_settings({"mcp_oauth_credentials_store": "file"})
    assert result.returncode == 0 and tomllib.loads(config.read_text())["mcp_oauth_credentials_store"] == "file", result

    # A setting it managed before and no longer defines is removed; the rest stays.
    result = merge_settings({})
    assert result.returncode == 0, result.stderr
    data = tomllib.loads(config.read_text())
    assert "mcp_oauth_credentials_store" not in data and data["model"] == "x", data

    # A value the user set by hand is never taken over.
    config.write_text('mcp_oauth_credentials_store = "keyring"\n' + config.read_text())
    result = merge_settings({"mcp_oauth_credentials_store": "file"})
    assert result.returncode == 0 and "leaving it unmanaged" in result.stderr, result
    assert tomllib.loads(config.read_text())["mcp_oauth_credentials_store"] == "keyring"
    assert json.loads(state.read_text()) == {"managed": []}

# A file Codex rewrote between reading and replacing it is never overwritten.
import importlib.util
spec = importlib.util.spec_from_file_location("codex_roles", SCRIPT)
codex_roles = importlib.util.module_from_spec(spec)
spec.loader.exec_module(codex_roles)
with tempfile.TemporaryDirectory() as tmp:
    path = os.path.join(tmp, "config.toml")
    pathlib.Path(path).write_text("trust = 'newer'\n")
    try:
        codex_roles.write_atomic(path, "merged\n", 0o600, expected="trust = 'older'\n")
    except codex_roles.ChangedError:
        pass
    else:
        raise AssertionError("a concurrent change must stop the replacement")
    assert pathlib.Path(path).read_text() == "trust = 'newer'\n"
    assert os.listdir(tmp) == ["config.toml"], "no temporary file is left behind"

print("codex role merge tests passed")
