# ADR-0081: Give agents a Forgejo MCP client and guard its merges

**Status:** Moved to a private repository on 2026-10-29
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
prefer it to `tea` and REST calls for forge operations; code still
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

Where the server is unavailable or lacks an operation, `tea` is the only CLI
fallback ([#616](https://git.alc.xyz/alcxyz/nix-config/issues/616)): `tea api` gives raw REST access with JSON output and reads
request bodies from stdin. `fj` is no longer installed: it has no raw API or
JSON output, and on Forgejo 15 it crashed on `pr status` and opened an editor
when a body was missing.

Shell merges stay available as `tea api -X POST /repos/owner/repo/pulls/N/merge`,
which the guard checks as a REST merge on its `url`. It refuses `tea pulls
merge`, because `tea --repo` is read as a local checkout when such a path
exists, and `fj pr merge`.

T3 Code's own pull request features also go through these CLIs: it tries `fj`
and then `tea`, and in both cases needs a stored login that matches the
repository remote, which it names with `--login`. Dropping `fj` therefore left
T3 without a usable login ([#704](https://git.alc.xyz/alcxyz/nix-config/issues/704)). Activation now keeps one stored tea login for
the instance with its URL and the SSH host of its remotes, adding no token, and
the tea wrapper drops `--login <that login>` when it has the token, so T3's
calls use the environment login; while the token file is set, naming that
login no longer selects it. The `t3code-forgejo-login-contract` check runs
T3's matching from the packaged bundle against that login; package promotion
runs it for every candidate, so a T3 update that changes the lookup stops
before the AI stack takes it.

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

`programs.ai.agentForge` (off by default, [#722](https://git.alc.xyz/alcxyz/nix-config/issues/722)) lets agent sessions act as a
separate, non-admin forge account while the operator's login shells keep the
operator's credentials and commits keep the operator's Git identity. T3 Code's
session wrapper, after reading the session variables, points
`FORGEJO_API_TOKEN_FILE` at the account's token, so `tea`, `pr-review` and the
guard's lookups use it, and adds `GIT_CONFIG_*` entries: for the forge's HTTPS
URL an empty `credential.<url>.helper` resets the helper list and the account's
helper (`forge-mirror credential-helper`, given the token file and user, never
the token) is the only one asked; `pushInsteadOf` sends pushes for the forge's
SSH forms over HTTPS, since an SSH push authenticates with the operator's key,
and maps the HTTPS form to itself. The private configuration sets the
account. The MCP wrapper's identity follows the session as well: it reads
`FORGEJO_API_TOKEN_FILE` when set (Codex is told to pass it on) and fails
when that file yields no token, and uses `tokenFile` only without it. A self-mapping
`insteadOf` was considered to outrank a host-wide `insteadOf` that sends HTTPS
to SSH, but Git gives a tie in prefix length to the rule read first, so the
global rule wins; `pushInsteadOf` applies to the remote's own URL before
`insteadOf` and is not affected. `agent-job` passes the token file and the
`GIT_CONFIG_*` entries on to its units, so a job an agent starts acts as the
account, and with the account enabled tea is always wrapped. The tea wrapper
fails when `FORGEJO_API_TOKEN_FILE` is set but yields no token, rather than
fall back to stored logins or an inherited `GITEA_TOKEN`; the helper answers
nothing in that case, so Git asks no other helper.

The session also points forge-mirror's `FORGEJO_TOKEN_FILE` at the account's
token and unsets `FORGEJO_TOKEN`, so forge-mirror's API calls from an agent
authenticate as the account. `FORGEJO_USER` stays the operator's: forge-mirror
reads it as the namespace whose repositories it works on, and the credential
helper alone names the account as its login. `agent-job` forwards the token
file and clears `FORGEJO_TOKEN` in its units.

This gives attribution and a guard against accidents, not a privilege
boundary: agents still run as the operator's Unix user, with the operator's
SSH key and credential files within reach. The private configuration's
decision on same-user agents covers that limit.

Limits, verified with Git 2.54: an explicit `remote.<name>.pushurl` is not
rewritten by `pushInsteadOf` but is by `insteadOf`, so it keeps its own
transport: an SSH one, or an HTTPS one under a host-wide `insteadOf` that
sends HTTPS to SSH, pushes over SSH as the operator (`forge-mirror primary`
clears push URLs; the legacy dual-push `sync` sets the forge's as HTTPS). An
operator-level `pushInsteadOf` with the same prefix is read first and wins.
Helpers for more specific URLs, with a path or a user, in configuration files
are read earlier and reset too. Only T3 Code sessions get this environment:
the `claude` and `codex` commands come from the package sets and the AI stack
profile, not from `programs.ai`, so a terminal session of either acts as the
operator end to end, MCP server included. Launchers placed ahead of the AI
stack on `PATH` could give them the account later.

## Alternatives Considered

- **A tool allowlist, with merges on shell paths only or behind a switch:**
  the original decision and its first amendment. Merges were left out while
  Codex hook coverage of MCP calls was unverified, and the allowlist kept
  administration and deletion tools away from agents. Once the hook tests
  passed, neither held: the guard covers MCP merges as it covers shell ones,
  and an allowlist cannot narrow a token agents can already use, so it only
  pushed agents to less structured tools.
- **`fj` as the CLI fallback:** the earlier choice, made during the guard work
  because its merges name a literal `owner/repo#N`. It lacks the raw API and
  JSON output agents need where the server falls short ([#616](https://git.alc.xyz/alcxyz/nix-config/issues/616)).
- **For T3's lookups: reinstall `fj`, store the token in tea's config, or
  patch T3:** `fj` would bring back a second plaintext token outside the
  activated file, a stored tea token would contradict the wrapper, and a T3
  patch would have to be carried through every upstream pin refresh in
  nix-packages ([#704](https://git.alc.xyz/alcxyz/nix-config/issues/704)).
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
token in its process environment. Where the activated token file exists, tea
runs with an environment login for git.alc.xyz built from it
(`modules/home-manager/programs/tea/`), which overrides stored logins. That
login has no username, so bare repository names and user-scoped commands such
as `tea org list` fail, and `tea clone <url>` still uses a stored login; agents
give `owner/repo` and clone with git. Elsewhere tea picks its login from the checkout's remotes, and every stored
login points at git.alc.xyz. Either way a `tea api` merge path is looked up
there. `tea` and `fj` calls that mention a pull request merge are blocked,
including help requests; text that only quotes such a command, for example in
a heredoc, can be blocked too. The client config
merges replace a file only if it is unchanged since it was read, but a client
save in the short gap before the replacement can be lost; activation is rare
and the client rewrites its state again.
