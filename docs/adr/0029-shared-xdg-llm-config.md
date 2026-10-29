# ADR-0029: Shared XDG LLM config for local tooling

**Status:** Accepted
**Date:** 2026-05-02
**Amended:** 2026-10-29
**History:** [replaced text](archive/0029-shared-xdg-llm-config-history.md)
**Applies to:** `nix-config`, `nix-packages/tools/devlog`, `tools/paperless-tools`

## Context

Several local tools support configurable providers and models. Each first did
so through its own config file with slightly different resolution rules, which
is the wrong shape for a user-level policy: the default provider stack should
be changeable in one place, not once per tool.

The desired posture is OpenAI through its local CLI as the primary provider,
Anthropic through its local CLI as the backup, and optional API support for
both when explicitly configured.

## Decision

`~/.config/llm/config.toml` is the source of truth for user-level LLM provider
policy across local tools. Tools resolve a model in this order:

1. Explicit tool invocation overrides, if the tool exposes them
2. The shared config at `~/.config/llm/config.toml`
3. One built-in default keyed by role name, used only when the shared config
   is missing

Tool-local config files are not read. If the shared config exists but is
invalid, or lacks the role a tool asks for, the tool fails clearly rather than
falling back.

## Shared config shape

The shared config has one entry per agent role (`light`, `standard`, `deep`),
under the role's name. Tools request role names; tasks that used the original
`fast` and `strong` tiers use `standard`, and moving a task to `light` is a
separate change for each tool.

Home Manager generates the file from the agent role table, which lives with
the agent modules in a private repository (moved there 2026-10-29 with
[ADR-0079](archive/0079-agent-model-roles.md) and
[ADR-0085](archive/0085-one-role-vocabulary.md)). `docs/llm-config.toml.example`
shows the shape with placeholder models. The hand-maintained
`users/alc/configs/llm/config.toml` and its live-edit link are retired.

### Fields

- `provider`: provider identifier such as `openai` or `anthropic`
- `model`: provider-specific model identifier
- `transport`: one of:
  - `cli`: require provider CLI transport
  - `api`: require provider API transport
  - `prefer-cli`: use CLI when supported, otherwise API if configured
  - `prefer-api`: use API when configured, otherwise CLI if supported
- `api_key_env`: optional env var name for API auth
- `effort`: optional reasoning effort for the CLI transports (Codex
  `model_reasoning_effort`, Claude Code `--effort`); empty keeps the CLI's
  default. Generated from the role. Added 2026-10-04.
- `backup`: optional provider/model entry with the same schema

Every generated role entry uses OpenAI with `cli` as the main entry and
Anthropic with `cli` as its backup. `api_key_env` is set on both, so API
transport remains available as optional future-proofing.

## Provider resolution rules

Each provider entry is resolved independently using its `transport` mode:

- `cli`: use provider CLI only; fail if the tool does not support that CLI
- `api`: use provider API only; fail if auth cannot be resolved
- `prefer-cli`: use CLI when supported, otherwise API if `api_key_env` resolves
- `prefer-api`: use API when `api_key_env` resolves, otherwise CLI when
  supported

If the main entry fails, the tool may try the configured backup entry.

### Auth resolution

For API transport, tools resolve auth consistently:

1. `<ENV_NAME>`
2. `<ENV_NAME>_FILE`

## Tool mapping guidance

This ADR does not require every tool to expose role names directly in its UI or
CLI; it only standardizes the underlying source of provider policy.

## Alternatives Considered

**Keep per-tool configs only:** Rejected. It duplicates user-level provider
policy and makes a default-provider change repetitive and error-prone.

**Keep tool-local configs as a fallback layer:** Used while the tools
migrated, then dropped on 2026-10-09 (ADR-0085): every tool reads the shared
config, and a third layer only hid stale defaults.

**Keep OpenAI as API-only:** Rejected. The desired direction is local CLI as
the primary path, with API as optional support.

**Keep the values in `nix-config`:** Rejected. The values are not secret, but
they come from the agent role table, which encodes agent delegation policy and
is kept beside the private agent instructions that name the same roles.
Secrets referenced by `api_key_env` remain separate.

## Consequences

- One generated file switches the provider stack for every tool that reads it,
  and a role tuning applies to agents and tools at once.
- Tool behavior is consistent across repos: shared config, else one built-in
  default per role.
- Tools must support the OpenAI CLI (Codex) transport, since it is the main
  entry of every role.
- API support remains available without forcing API billing as the default path.
