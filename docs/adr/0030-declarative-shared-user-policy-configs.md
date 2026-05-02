# ADR-0030: Declarative deployment for shared user policy configs

**Status:** Accepted
**Date:** 2026-05-02
**Applies to:** `nix-config`, `nix-secrets`, home-manager managed user config surfaces

## Context

Some configuration files are not just application settings for one program.
They are shared user-level policy surfaces consumed by multiple tools or agent
environments.

Recent examples:

- `~/AGENTS.md` and `~/.claude/CLAUDE.md` as universal agent instruction
  surfaces
- `~/.config/llm/config.toml` as shared provider/model policy for local AI
  tooling

These files have a different role from ordinary per-app config:

- multiple tools depend on them
- their location and contents are part of a cross-tool contract
- drift or ad-hoc bootstrapping creates inconsistent behavior
- users expect a rebuild to establish the canonical state

The project needs a general rule for how such shared user policy configs are
owned, versioned, and deployed.

## Decision

Shared user policy configs should be source-controlled and deployed
declaratively through Home Manager rather than created independently by each
tool at runtime.

The default pattern is:

1. Keep the canonical source file in version control
2. Deploy it to the user-visible target path via Home Manager
3. Make tools read that canonical path as their primary policy surface
4. Use tool-local config only as fallback during migration or for explicit
   tool-specific overrides
5. Keep secrets separate from the shared policy file itself

## What qualifies as a shared user policy config

A config surface falls under this ADR when most of the following are true:

- more than one tool or agent depends on it
- it expresses user-level policy rather than one tool's local preferences
- a consistent path matters across machines
- the file should be understandable and editable outside the consuming tool
- rebuild-based deployment is desirable

Examples that fit:

- shared LLM provider policy
- universal agent instruction files
- future cross-tool workflow or policy configs

Examples that usually do not fit:

- a single application's internal cache or state file
- ephemeral generated config that exists only to support one binary
- host-local runtime data that should not be source-controlled

## Placement rules

Choose the source repo based on the file's nature:

- `nix-config` for non-secret canonical policy/config files
- `nix-secrets` for secret or security-sensitive material that must live in the
  private repo

Deployment still happens through Home Manager in `nix-config`, even when the
source of truth lives in `nix-secrets`.

## Deployment rules

Preferred deployment shape:

- keep the canonical file in a stable source path
- link it into place via `xdg.configFile` or `home.file`
- preserve live-editing workflows using `mkOutOfStoreSymlink` when that is the
  established pattern

This means a rebuild should establish the expected file path automatically.

## Runtime behavior rules

Tools that consume a shared user policy config should:

1. look for the shared canonical path first
2. fail clearly if that shared file exists but is invalid
3. fall back to older per-tool config only when the shared file is absent
4. avoid silently generating competing canonical files at first run

Per-tool bootstrap may still be acceptable for narrow single-tool config, but
it is not the default for shared policy surfaces.

## Relationship to secrets

Shared user policy configs are not a place to embed secret values.

If the policy needs secret-backed settings, the config should reference them
indirectly, for example via:

- environment variable names
- `_FILE` indirection
- secret paths managed elsewhere

This keeps the policy file source-controllable while secret material remains in
the proper secret-management flow.

## Examples

### Agent instructions

- canonical source files live in `nix-secrets/shared/`
- Home Manager deploys them to `~/AGENTS.md` and `~/.claude/CLAUDE.md`
- `check-agent-sync` enforces the allowed compatibility delta

### Shared LLM config

- canonical source file lives at `users/alc/configs/llm/config.toml`
- Home Manager deploys it to `~/.config/llm/config.toml`
- tools prefer that path over older tool-local config files

## Alternatives Considered

**Let each tool bootstrap the file on first run:** Rejected as the default.
This fragments ownership and tends to produce drift in both contents and
location.

**Keep all such files in `nix-secrets`:** Rejected. Many shared policy files
are not secret and belong in the public config repo.

**Do nothing, rely on conventions only:** Rejected. The same pattern has now
appeared more than once, which is enough to justify an explicit rule.

## Consequences

- Shared user policy surfaces become predictable across machines.
- Rebuilds establish canonical config paths automatically.
- Tool implementations get a clearer contract: read the shared file first,
  then fall back only for compatibility.
- Secret handling stays separate from policy handling.
- Future cross-tool policy configs have a reusable standard instead of ad-hoc
  bootstrap behavior.
