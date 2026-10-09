# ADR-0085: One role vocabulary for agents and tools

**Status:** Accepted
**Date:** 2026-10-09
**Applies to:** `modules/home-manager/programs/ai/roles.nix`, `docs/llm-config.toml.example`, `~/.config/llm/config.toml`, nix-secrets role table and agent instructions, and the tools that read the shared LLM config: paperless-tools, mailweight, crm-ingest and devlog

## Context

ADR-0079 introduced agent roles (`light`, `build`, `deep`) and generated the
shared LLM config (ADR-0029) from them. Tools still ask for that config's own
tiers, `fast` and `strong`, which `programs.ai.llmConfigRoles` maps onto
agent roles. Both tiers map to `build`, so the second vocabulary adds a
mapping to every tuning without making a choice of its own. Tools such as
mailweight already use agent roles through `agent-role` as well, so the two
vocabularies also mix within a single tool.

`build` has also outgrown its name. It now covers bounded implementation,
document drafting and review, summaries and audits: it is the standard tier
between `light` and `deep`.

Each tool reading the shared config also keeps a tool-local config file and
built-in defaults from before ADR-0029, so a model is resolved through three
layers, and the defaults have gone stale.

## Decision

- `build` is renamed `standard`. The roles are `light`, `standard` and `deep`.
- `~/.config/llm/config.toml` has one entry per agent role, under the role's
  name, with the same model, effort and cross-provider backup as before.
  `llmConfigRoles` holds only temporary aliases and is removed with them.
- Tools request role names. Moving from the tiers keeps their models
  unchanged: `fast` and `strong` both become `standard`. Moving a task to
  `light` is a separate change for each tool, made after its own sample check.
- Tools read the shared config, or fall back to one built-in default keyed by
  role name when it is missing. Tool-local config files are no longer read.

The rename follows ADR-0079's ordering. The role table adds `standard` next
to `build`, and the generator writes every role plus `fast` and `strong` as
aliases of `standard`. After that is deployed, tools and instructions move to
the role names. Finally `build`, the aliases and `llmConfigRoles` are removed.

## Alternatives Considered

- **Keep `fast` and `strong` as a stable contract for tools:** decouples the
  tools from role names. But no tier has ever chosen differently from a role,
  and the indirection has to be kept in step with every role change.
- **Tools read `~/.config/agent-roles/roles.json` or call `agent-role`:**
  removes the separate file, but drops the provider, transport and backup
  fields the tools use, and changes every loader.
- **Other names for `build`:** `default` is a built-in Codex agent type, and
  `medium` would be confused with the effort level.

## Consequences

A role tuning applies to agents and tools at once, with no mapping to update.
Renaming or removing a role now also touches the tools that name it, and those
tools are public, so role names (not their models) are public too. A tool that
asks for a role missing from the shared config fails clearly, as ADR-0029
requires for an invalid config.

ADR-0029 and ADR-0079 are amended accordingly.
