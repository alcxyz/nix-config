# ADR-0084: Keep Codex MCP OAuth credentials in a file, not the keyring

**Status:** Accepted
**Date:** 2026-10-07
**Applies to:** `modules/home-manager/programs/ai/`, Codex CLI user configuration

## Context

Codex's `mcp_oauth_credentials_store` defaults to `auto`, which uses the
desktop Secret Service when one is present. Codex 0.160 looks up MCP
credentials there whenever it starts or resumes a session, even when no
configured server uses OAuth, and waits without a timeout.

When gnome-keyring-daemon restarts during a session, its login collection
comes back locked and a lookup waits for an unlock prompt. Every Codex
session, including those the T3 Code app-server drives, then stops at session
start with no error, and restarting T3 Code does not help. This happened on
xyz after the daemon aborted in `OpenSession`, a crash with no fixed release
available.

Codex already keeps its ChatGPT login in `~/.codex/auth.json`, a private file.

## Decision

Activation sets `mcp_oauth_credentials_store = "file"` in
`~/.codex/config.toml`, so MCP OAuth tokens are stored in a private file under
`~/.codex` and Codex sessions do not depend on the keyring's state.
`pr-review` runs Codex with `--ignore-user-config`, so it passes the same
setting with `-c`.

The setting is managed like the agent roles and MCP servers: the Codex table
merge (ADR-0079, ADR-0081) gains a top-level mode and records the keys it
manages. A value the user set before the merge first ran is left in place with
a warning; once the key is managed, activation restores the managed value, as
for the role and MCP tables.

## Alternatives Considered

- **Keep the keyring and make it reliable.** The crash is upstream and a
  restarted daemon is always locked until someone unlocks it, so Codex would
  still hang until then.
- **Set the option in `/etc/codex/managed_config.toml`.** That covers NixOS
  hosts only, not macOS, and is a system-wide layer outside Home Manager's
  per-user configuration.
- **Pass `-c` overrides when starting Codex.** T3 Code and other clients start
  Codex themselves, so the overrides would not reach every session; only
  `pr-review`, which skips user configuration, needs one.

## Consequences

- MCP OAuth tokens are protected by file permissions only, like `auth.json`,
  rather than by the keyring's encryption while it is locked.
- Servers whose tokens were in the keyring need `codex mcp login <server>`
  once. Stdio servers that read their own token files, such as `forgejo`, are
  unaffected.
- A locked keyring can still stall other keyring clients; that is outside this
  decision.
