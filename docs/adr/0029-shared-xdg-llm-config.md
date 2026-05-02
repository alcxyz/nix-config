# ADR-0029: Shared XDG LLM config for local tooling

**Status:** Accepted
**Date:** 2026-05-02
**Applies to:** `nix-config`, `nix-packages/tools/devlog`, `tools/leantime-tidy`, `tools/paperless-tools`

## Context

Several local tools now support configurable providers and models, but they do
so through separate config files and slightly different resolution rules:

- `devlog` reads `~/.config/devlog/config.toml`
- `leantime-tidy` reads `~/.config/leantime-tidy/config.toml`
- `paperless-tools` reads `~/.config/paperweight/config.toml`

That solved the immediate "stop hardcoding Claude everywhere" problem, but it
is the wrong shape for a user-level policy change. The desired steady state is:

- OpenAI via local CLI as the primary provider for local tooling
- Anthropic via local CLI as the backup provider
- Optional API support for both providers when explicitly configured
- Per-tool config as a fallback or exceptional override, not the primary policy
  surface

This is a user-level concern, not a tool-level concern. The default provider
stack should be changeable in one place.

## Decision

Adopt a shared XDG config at `~/.config/llm/config.toml` as the preferred
source of truth for user-level LLM provider policy across local tools.

Tools should migrate to the following precedence order:

1. Explicit tool invocation overrides, if the tool exposes them
2. Shared XDG LLM config at `~/.config/llm/config.toml`
3. Existing tool-local config
4. Tool built-in defaults

If the shared config exists but is invalid, tools should fail clearly rather
than silently falling back to lower-precedence config.

## Shared config shape

The shared config is role-based. Tools map their own tasks onto shared roles
such as `fast` and `strong`.

Example:

```toml
[roles.fast]
provider    = "openai"
model       = "gpt-5.4-mini"
transport   = "cli"
api_key_env = "OPENAI_API_KEY"

[roles.fast.backup]
provider    = "anthropic"
model       = "claude-haiku-4-5-20251001"
transport   = "cli"
api_key_env = "ANTHROPIC_API_KEY"

[roles.strong]
provider    = "openai"
model       = "gpt-5.4"
transport   = "cli"
api_key_env = "OPENAI_API_KEY"

[roles.strong.backup]
provider    = "anthropic"
model       = "claude-sonnet-4-6-20250514"
transport   = "cli"
api_key_env = "ANTHROPIC_API_KEY"
```

A checked-in reference copy lives at `docs/llm-config.toml.example`.
The canonical deployed user config lives at
`users/alc/configs/llm/config.toml` and is linked into
`~/.config/llm/config.toml` via home-manager.

### Fields

- `provider`: provider identifier such as `openai` or `anthropic`
- `model`: provider-specific model identifier
- `transport`: one of:
  - `cli` — require provider CLI transport
  - `api` — require provider API transport
  - `prefer-cli` — use CLI when supported, otherwise API if configured
  - `prefer-api` — use API when configured, otherwise CLI if supported
- `api_key_env`: optional env var name for API auth
- `backup`: optional provider/model entry with the same schema

The intended default posture is OpenAI primary with `cli`, Anthropic backup
with `cli`, and API settings present only as optional future-proofing.

## Provider resolution rules

Each provider entry is resolved independently using its `transport` mode:

- `cli`: use provider CLI only; fail if the tool does not support that CLI
- `api`: use provider API only; fail if auth cannot be resolved
- `prefer-cli`: use CLI when supported, otherwise API if `api_key_env` resolves
- `prefer-api`: use API when `api_key_env` resolves, otherwise CLI when
  supported

If the main entry fails, the tool may try the configured backup entry.

### Auth resolution

For API transport, tools should resolve auth consistently:

1. `<ENV_NAME>`
2. `<ENV_NAME>_FILE`

## Migration rules

Tool migrations should follow this order:

1. Implement shared-config loading
2. Implement OpenAI CLI support where missing
3. Preserve existing Anthropic CLI and optional API support
4. Keep tool-local config as fallback while migration is in progress
5. Only then flip operational defaults to OpenAI primary and Anthropic backup

The migration should not require immediate deletion of tool-local config. Those
files remain valid fallback layers until all tools are updated.

## Tool mapping guidance

- `paperless-tools` continues to use shared roles directly (`fast`, `strong`)
- `leantime-tidy` should use `fast` by default
- `devlog` should use `strong` by default unless a narrower role is introduced
  later

This ADR does not require every tool to expose role names directly in its UI or
CLI; it only standardizes the underlying source of provider policy.

## Alternatives Considered

**Keep per-tool configs only:** Rejected. It duplicates user-level provider
policy and makes a default-provider change repetitive and error-prone.

**Shared config only, no tool-local fallback:** Rejected for now. It would make
the final model cleaner, but it creates unnecessary migration pressure and
would break tools that have not adopted the shared config yet.

**Keep OpenAI as API-only:** Rejected. The desired direction is local CLI as
the primary path, with API as optional support.

**Put the shared config in `nix-secrets`:** Rejected. This is configuration
policy, not secret material. Secrets referenced by `api_key_env` remain
separate.

## Consequences

- One config file can switch the primary provider stack for multiple tools.
- Tool behavior becomes more consistent across repos.
- OpenAI CLI support becomes a concrete implementation requirement.
- Existing tool-local configs remain useful during migration, but no longer
  represent the long-term source of truth.
- API support remains available without forcing API billing as the default path.
