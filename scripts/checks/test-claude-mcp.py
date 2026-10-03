#!/usr/bin/env python3
"""Contract tests for the Claude Code MCP server merge (ADR-0081)."""

import json
import os
import pathlib
import stat
import subprocess
import sys
import tempfile

SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "modules/home-manager/programs/ai/claude-mcp.py"
SERVER = {"type": "stdio", "command": "/profile/bin/forgejo-mcp-agent", "args": [], "env": {}}

with tempfile.TemporaryDirectory() as tmp:
    root = pathlib.Path(tmp)
    config = root / "home" / ".claude.json"
    state = root / "state" / "agent-mcp" / "claude-managed.json"
    servers = root / "servers.json"

    def merge(entries):
        servers.write_text(json.dumps(entries))
        return subprocess.run([sys.executable, str(SCRIPT), str(config), str(state), str(servers)],
                              capture_output=True, text=True)

    # Nothing to manage leaves a missing config alone.
    assert merge({}).returncode == 0 and not config.exists()

    # A first run creates a private config and records what it manages.
    result = merge({"forgejo": SERVER})
    assert result.returncode == 0, result.stderr
    assert json.loads(config.read_text()) == {"mcpServers": {"forgejo": SERVER}}
    assert stat.S_IMODE(config.stat().st_mode) == 0o600
    assert json.loads(state.read_text()) == {"managed": ["forgejo"]}

    # Claude's own state and the user's servers are kept; the mode is preserved.
    config.write_text(json.dumps({"numStartups": 3, "mcpServers": {"mine": {"command": "x"}, "forgejo": {"command": "old"}}}))
    os.chmod(config, 0o640)
    result = merge({"forgejo": SERVER})
    assert result.returncode == 0, result.stderr
    data = json.loads(config.read_text())
    assert data == {"numStartups": 3, "mcpServers": {"mine": {"command": "x"}, "forgejo": SERVER}}, data
    assert stat.S_IMODE(config.stat().st_mode) == 0o640

    # An unchanged result leaves the file untouched.
    before = config.stat().st_mtime_ns
    assert merge({"forgejo": SERVER}).returncode == 0 and config.stat().st_mtime_ns == before

    # A dropped server is removed; the user's stay.
    assert merge({}).returncode == 0
    assert json.loads(config.read_text())["mcpServers"] == {"mine": {"command": "x"}}

    # A hand-made server with a managed name is never taken over.
    result = merge({"mine": SERVER})
    assert result.returncode == 0 and "leaving it unmanaged" in result.stderr, result
    assert json.loads(config.read_text())["mcpServers"] == {"mine": {"command": "x"}}

    # Invalid JSON, non-objects and symbolic links fail without changes.
    for content in ("{broken", "[]", '{"mcpServers": []}'):
        config.write_text(content)
        result = merge({"forgejo": SERVER})
        assert result.returncode == 1 and "existing config was preserved" in result.stderr, result
        assert config.read_text() == content
    target = root / "target.json"
    target.write_text("{}")
    config.unlink()
    config.symlink_to(target)
    assert merge({"forgejo": SERVER}).returncode == 1 and target.read_text() == "{}"

print("claude MCP merge tests passed")
