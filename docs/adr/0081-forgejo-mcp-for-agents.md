# ADR-0081: Give agents a Forgejo MCP client and guard its merges

**Status:** Accepted (revised 2026-10-05: every tool exposed, merges guarded)
**Date:** 2026-10-03
**Applies to:** `modules/home-manager/programs/ai/`, Claude Code and Codex CLI user configuration

## Context

Agents work with Forgejo issues and pull requests by parsing `fj` and `tea`
output or by writing ad-hoc REST scripts, which is slow and error-prone
([#521](https://git.alc.xyz/alcxyz/nix-config/issues/521)). forgejo-mcp
(nixpkgs, 3.0.1) offers about 150 typed tools over a local stdio transport,
including `merge_pull_request`.

The rule agent forge access must respect is ADR-0078: an agent merges a PR it
created only after a review comment for the PR's current head. Agents can
already read the agent API token, so any forge operation is one REST call away;
restricting the MCP tool set limits only the MCP path, not what agents can do.
The ADR-0078 guard runs as a `PreToolUse` hook in both clients and sees MCP
calls: Claude Code matches them by name, hooks run even when permission prompts
are bypassed, and tests on Codex 0.160 showed that its hooks see direct MCP
calls and calls from its code-mode tool under the same `mcp__forgejo__` name,
with the arguments as `tool_input`, and that exit code 2 blocks them.

## Decision

`programs.ai.forgejoMcp` runs forgejo-mcp as a local stdio server named
`forgejo` for Claude Code and Codex, with every tool exposed. Agents should
prefer it to `fj`, `tea` and REST calls for forge operations; code still
changes through git.

The guard checks `merge_pull_request` like any other merge and lets other tools
pass. It needs a review comment for the PR's current head on the server's
`url`, which must be the guard's own instance, and literal `owner`, `repo` and
`index` arguments. It accepts only the tool's known arguments, with
`force_merge` and `merge_when_checks_succeed` only as false, because both merge
later at a head the review may not cover. Both clients' `forgejo`
registrations must be the managed ones, as recorded by the registration
helpers; a hand-made entry they left in place may point at another instance.
The guard does not read client configuration, so registrations made outside
`programs.ai` (another `CODEX_HOME` or `CLAUDE_CONFIG_DIR`, project files,
command-line servers, or an entry edited after activation) are not verified.

The tools get no special approval settings; each client's permission mode
decides, as for its other tools.

Shell merges stay available. The guard also recognises `fj pr merge` and needs
a literal `owner/repo#N`. It refuses `tea` merges: `tea --repo` is read as a
local checkout when such a path exists, so the guard cannot tell which
repository a tea merge targets.

Registration follows the existing managed merges: activation adds the server
to `[mcp_servers.forgejo]` in `~/.codex/config.toml` (the role merge, now
generic over the table) and to `mcpServers.forgejo` in `~/.claude.json`, and
removes it again when disabled. Entries the user added, including a hand-made
entry of the same name, are left alone.

A wrapper, `forgejo-mcp-agent`, reads the token from `tokenFile` when the
server starts and passes it in `FORGEJO_ACCESS_TOKEN`, so it never appears in
arguments or client configuration. `tokenFile` defaults to the session's
`FORGEJO_API_TOKEN_FILE`, which the private configuration provisions. The
wrapper is referenced by store path and kept off `PATH`, because the guard sees
its merges only as client tool calls.

## Alternatives Considered

- **A tool allowlist, with merges on shell paths only or behind a switch:**
  the original decision and its first amendment. Merges were left out while
  Codex hook coverage of MCP calls was unverified, and the allowlist kept
  administration and deletion tools away from agents. Once the hook tests
  passed, neither held: the guard covers MCP merges as it covers shell ones,
  and an allowlist cannot narrow a token agents can already use, so it only
  pushed agents to less structured tools.
- **A forge-side control:** rejected in ADR-0078; anyone can post the comment,
  and it would change the forge for an accident guard.
- **A dedicated, narrower token:** agents can already read the existing agent
  API token, so a second token would not reduce what they can do. `tokenFile`
  can point to a narrower token later without changes here.
- **A network or in-cluster server:** out of scope; it adds an access point to
  the forge and would be a separate GitOps decision.
- **Keep ad-hoc REST scripts:** works, but is what this change replaces.

## Consequences

Agents on hosts with `programs.ai.forgejoMcp.enable` reach every forgejo-mcp
tool, including deletion and administration, and new upstream tools appear
without module changes. Codex 0.160 loads MCP tool definitions on demand, so
exposing all tools adds no input tokens to a session that does not use them.
Merges stay held to ADR-0078 wherever the guard runs as a hook; where it does
not, MCP merges are as unguarded as shell merges. `permissions.allow` rules for
`mcp__forgejo__` tools from the earlier allowlist stay in Claude Code user
settings until removed by hand. The server talks only to `url` and holds the
token in its process environment. `fj` merges with an implicit repository are
blocked with guidance rather than resolved, because fj's own remote selection
cannot be reproduced reliably. The guard looks them up on `url` unless `-H`
names another host, which is blocked; an fj that picks another instance from
its checkout usually fails the lookup and blocks, but is not verified. `fj`
calls that mention a merge in a form the guard does not parse are blocked,
including help requests and commands split by newlines; text that only quotes
such a command, for example in a heredoc, can be blocked too. The client config
merges replace a file only if it is unchanged since it was read, but a client
save in the short gap before the replacement can be lost; activation is rare
and the client rewrites its state again.
