# ADR-0081: Give agents a Forgejo MCP client with an allowlist

**Status:** Accepted
**Date:** 2026-10-03
**Applies to:** `modules/home-manager/programs/ai/`, Claude Code and Codex CLI user configuration

## Context

Agents work with Forgejo issues and pull requests by parsing `fj` and `tea`
output or by writing ad-hoc REST scripts, which is slow and error-prone
([#521](https://git.alc.xyz/alcxyz/nix-config/issues/521)). forgejo-mcp
(nixpkgs, 3.0.1) offers typed tools over a local stdio transport. It exposes
about 150 tools, including `merge_pull_request` and organization, branch
protection, webhook, file and attachment tools. All of them are annotated
destructive, and the server cannot limit its own tool set.

ADR-0078 requires a current-head review record before an agent merges a PR it
created. Its guard inspects shell commands only, so an MCP merge tool would be
a new, unguarded path. The guard also did not recognise `fj pr merge` and
`tea pulls merge`.

## Decision

`programs.ai.forgejoMcp` runs forgejo-mcp as a local stdio server named
`forgejo` for Claude Code and Codex, with a fixed tool allowlist:

- **Reads** (`readTools`): issues, PRs, diffs, reviews, comments, repository
  contents, commits, branches, labels, milestones, releases and workflow runs.
  Codex approves them automatically; Claude Code receives managed
  `permissions.allow` rules for them.
- **Writes** (`writeTools`): create, edit, label, link and close issues; comment;
  create and edit PRs. They keep each client's approval (Codex
  `approval_mode = "prompt"`, Claude Code's permission mode).
- **Not exposed:** merges, deletion, administration, file writes, attachments
  (which upload local files), webhooks, releases, workflow dispatch and time
  tracking. The module refuses a configuration that enables
  `merge_pull_request`.

Merges stay on the shell paths that the ADR-0078 guard verifies. The guard now
also recognises `fj pr merge` and needs a literal `owner/repo#N`. It refuses
`tea` merges: `tea --repo` is read as a local checkout when such a path exists,
so the guard cannot tell which repository a tea merge targets.

Each client gets the allowlist where it can enforce it. Codex receives
`enabled_tools`, so other tools are hidden. Claude Code has no per-server tool
filter, so the guard hook also matches `mcp__forgejo__.*` and blocks tools
outside the allowlist; hooks run even when permission prompts are bypassed.

Registration follows the existing managed merges: activation adds the server
to `[mcp_servers.forgejo]` in `~/.codex/config.toml` (the role merge, now
generic over the table) and to `mcpServers.forgejo` in `~/.claude.json`, and
removes it again when disabled. Entries the user added, including a hand-made
entry of the same name, are left alone.

A wrapper, `forgejo-mcp-agent`, kept off `PATH`, reads the token from `tokenFile` when the
server starts and passes it in `FORGEJO_ACCESS_TOKEN`, so it never appears in
arguments or client configuration. `tokenFile` defaults to the session's
`FORGEJO_API_TOKEN_FILE`, which the private configuration provisions.

## Alternatives Considered

- **Guard MCP merges with the review check:** would allow reviewed merges
  through MCP, but Codex hook coverage of MCP calls is not verified, so one
  client could merge unguarded. Keeping merges on shell paths gives one guarded
  route.
- **A forge-side control:** rejected in ADR-0078; anyone can post the comment,
  and it would change the forge for an accident guard.
- **Expose every tool and rely on prompts:** sessions often bypass prompts, and
  the administration tools are far outside agent work.
- **A dedicated, narrower token:** agents can already read the existing agent
  API token, so a second token would not reduce what they can do; the
  allowlist is the effective limit. `tokenFile` can point to a narrower token
  later without changes here.
- **A network or in-cluster server:** out of scope; it adds an access point to
  the forge and would be a separate GitOps decision.
- **Keep ad-hoc REST scripts:** works, but is what this change replaces.

## Consequences

Agents on hosts with `programs.ai.forgejoMcp.enable` can list, read and comment
on issues and PRs through typed tools. A forgejo-mcp update can rename tools;
a renamed read tool then prompts or is blocked until the allowlist is updated.
New upstream tools stay unavailable until added. Claude Code still lists the
blocked tools, and `permissions.allow` rules dropped from the module stay in
user settings until removed by hand. The server talks only to `url` and holds
the token in its process environment. `fj` merges with an implicit repository
are blocked with guidance rather than resolved, because fj's own remote
selection cannot be reproduced reliably. The guard looks them up on `url`
unless `-H` names another host, which is blocked; an fj that picks another
instance from its checkout usually fails the lookup and blocks, but is not
verified. `fj` calls that mention a merge in a form the guard does not parse
are blocked, including help requests and commands split by newlines; text
that only quotes such a command, for example in a heredoc, can be blocked too. The hook matches the
server name, so a hand-made Claude Code server also named `forgejo` is held to
the same allowlist. The wrapper is
referenced by store path and kept off `PATH`, because it serves every
forgejo-mcp tool to whoever runs it. The client config merges replace a file
only if it is unchanged since it was read, but a client save in the short gap
before the replacement can be lost; activation is rare and the client rewrites
its state again.
