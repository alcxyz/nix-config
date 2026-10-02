# ADR-0079: Name agent model roles instead of model versions

**Status:** Accepted (implemented 2026-10-02)
**Date:** 2026-10-02
**Applies to:** `modules/home-manager/programs/ai/`, `users/alc/common.nix`, `docs/llm-config.toml.example`, the retired `users/alc/configs/llm/config.toml`, `~/.codex/config.toml`, `~/.codex/<role>.config.toml`, `~/.claude/agents/`, `~/.config/llm/config.toml`, nix-secrets role table and agent instructions

## Context

Agent instructions, `pr-review` (ADR-0078), the shared LLM config (ADR-0029)
and repository instructions each name concrete model versions. Every model
release means editing several places, and they drift apart: on 2026-10-02 the
shared LLM config still used an older OpenAI model, and its Claude backup named
a model ID that does not exist. The backup runs only when the primary fails, so
nothing noticed.

Both agent clients can name a configuration and select it at run time. This was
verified on 2026-10-02 with Codex CLI 0.160 and Claude Code 2.1.287:

- `codex exec -p <name>` layers `$CODEX_HOME/<name>.config.toml`, including
  `model` and `model_reasoning_effort`.
- An `[agents.<name>]` entry whose `config_file` points at that same file makes
  Codex subagents spawned with `agent_type = <name>` use its model and effort.
- Claude Code agent definitions (`~/.claude/agents/<name>.md`) select a model
  alias and effort. They work for `claude -p --agent <name>` and as subagent
  types. The `sonnet` and `opus` aliases resolve to the current model of each
  line.
- OpenAI model names always carry a version; Codex offers no floating alias.

## Decision

Instructions and tools name **roles**, not models. Each role is a small,
stable vocabulary entry describing the kind of work:

- `light`: simple, well-scoped mechanical work.
- `build`: bounded implementation.
- `deep`: involved implementation, debugging and independent review that need
  deeper, more persistent iteration.

`programs.ai.roles` maps each role to a Codex model and a Claude alias, each
with an effort setting. The role generation is imported from
`users/alc/common.nix`, so every Home Manager user that receives the shared
agent instructions, including the Darwin host, also receives the role
configuration, independent of `programs.ai.enable`, which keeps gating
`pr-review` and its merge guard. The generated configuration is:

- One Codex role file per role, linked as `~/.codex/<role>.config.toml` for
  `codex exec -p <role>`. Roles cover the default Codex home only; sessions
  with a custom `CODEX_HOME` (ADR-0022) do not get them.
- Codex `[agents.<role>]` registrations in `~/.codex/config.toml`, pointing at
  the same files by absolute path. Codex also writes this file, so activation
  merges only the managed role tables, as the Claude settings merge (ADR-0078)
  does for hooks. Unlike that merge, it records the role names it manages in a
  state file under `~/.local/state/`, and removes the tables of recorded roles
  that are no longer defined. Everything else Codex wrote stays. The merge
  checks the parsed result, refuses layouts it cannot change safely, and does
  not replace the file if Codex saved it meanwhile; without a lock shared with
  Codex, a save in the instant between that check and the rename can still be
  lost. A failed merge only warns, because `-p <role>` keeps working.
- One Claude agent definition per role in `~/.claude/agents/`. A definition's
  body becomes that agent's system prompt, so each carries a short
  general-purpose prompt and inherits the default tools; it exists for
  delegation, not to restrict the agent.
- `~/.config/llm/config.toml`, whose `fast` and `strong` roles (ADR-0029) are
  chosen from the agent roles, each with a backup on the other provider. It
  replaces the hand-maintained `users/alc/configs/llm/config.toml`. Generated
  Anthropic entries use the CLI transport, because aliases are Claude Code
  names rather than API model IDs; the schema has no effort field.
- `pr-review` reviewer defaults, from the `deep` role on both providers.

Tools that only need a model receive the role's resolved model and effort
rather than a profile or agent definition. `pr-review` in particular keeps
ignoring user configuration (ADR-0078), so it passes the resolved values
(`-m` and `model_reasoning_effort` for Codex, `--model` and `--effort` for
Claude) and never uses `-p <role>`. Because a Claude alias can move between
deploys, `pr-review` records the model each client reports, not the alias it
was given.

Claude roles use aliases, so they follow new releases without changes. Codex
roles name exact models and change in one place. Every generated file comes
from the same Home Manager switch, so a role's files and registrations change
together.

The concrete mapping is a private default in `nix-secrets`, next to the shared
agent instructions that use the role names, and reaches this repository through
the existing flake input. This reverses ADR-0029's choice to keep the shared LLM
config out of `nix-secrets`: the table now also encodes delegation policy whose
wording lives in those private instructions, and reviewing both together
outweighs keeping plain configuration public. The instructions are linked live
from the checkout while the table arrives with a lock refresh and deploy, so
changes are ordered: deploy a new or renamed role to every host that receives
the instructions before they name it, and stop naming a role before removing
it. Changing a role's model needs no
ordering, because instructions never name models: one reviewed edit, a lock
refresh and a deploy.

Work is tracked in [#522](https://git.alc.xyz/alcxyz/nix-config/issues/522).

## Alternatives Considered

- **Keep naming models in instructions:** no tooling, but every release edits
  several repositories and the copies keep drifting.
- **Claude aliases only:** fixes half the problem; Codex has no equivalent, and
  instructions would still mix aliases with versioned OpenAI names.
- **Register roles in Codex's system layer `/etc/codex/config.toml`:** avoids
  merging into a file Codex writes, but `programs.ai` is a standalone Home
  Manager module and cannot write `/etc`. Host rebuilds would then deliver
  registrations separately from the role files, and a system-wide file would
  point at one user's files.
- **Role values in nix-config, as ADR-0029 chose for the LLM config:** keeps
  public configuration public, but separates the table from the private
  instructions that define when to use each role, so a role change needs
  coordinated reviews in two repositories.

## Consequences

Instructions stay valid across model releases, and a role can move to another
model without touching them. Agents still choose the role, so the vocabulary
must stay small and its descriptions precise.

Codex model updates still need a deploy, and a retired model fails until the
role is updated; Codex's model list publishes retirement notices that a later
check can turn into an issue. An alias moves to a new Claude model as soon as
the client knows it, which can change behaviour without review. To hold a
version back, the role names an exact Claude model instead of an alias; that
pin applies everywhere, including `pr-review`, which ignores Claude settings.

Role names must not collide with built-in agent types: `Explore`, `Plan`,
`general-purpose` and `claude` in Claude Code, and `default`, `explorer` and
`awaiter` in Codex.

The role files rely on Codex's file-based profiles (`-p` loading
`<name>.config.toml`); older Codex versions selected `[profiles.<name>]` inside
`config.toml` instead. Whether `claude --agent <role>` sessions keep Claude
Code's default behaviour with a role's prompt is verified before instructions
rely on it.

ADR-0029 and ADR-0030 are amended for the shared LLM config source and
placement, and ADR-0078 for the reviewer defaults.
