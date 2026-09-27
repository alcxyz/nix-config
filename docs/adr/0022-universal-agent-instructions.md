# ADR-0022: Universal Agent Instructions via AGENTS.md

**Status:** Accepted, amended 2026-09-26
**Date:** 2026-04-26
**Applies to:** `nix-secrets/shared/AGENTS.md`, `nix-secrets/shared/claude/CLAUDE.md`, `nix-config/users/alc/common.nix`

## Context

Universal instructions previously lived in `AGENTS.md` and a manually mirrored
`CLAUDE.md`, with a packaged comparison tool enforcing an allowed Claude-only
delta. This added maintenance and drift risk to every instruction change.

Claude Code now documents automatic `@path` imports at startup, including trusted
imports from user-level `~/.claude/CLAUDE.md`. Unlike a prose instruction to read
another file, an import does not depend on the model choosing to use a tool.
Native project `AGENTS.md` discovery is also available from v2.1.277, but its
default behavior depends on whether project or ancestor Claude files exist.

## Decision

Keep universal rules only in `nix-secrets/shared/AGENTS.md`, deployed to
`~/AGENTS.md`. Keep `~/.codex/AGENTS.md` linked to that canonical path.

Keep `nix-secrets/shared/claude/CLAUDE.md` as a small adapter: `@~/AGENTS.md`
followed only by Claude-specific Agent tool guidance. Home Manager continues to
link it to `~/.claude/CLAUDE.md`; live source edits require no rebuild.

Remove the mirrored content and retire `check-agent-sync`, its package export,
and its shared package-set entry. This supersedes ADR-0028. Keep universal rules
thin and move detailed procedures into linked documentation or skills.

## Alternatives Considered

- **Native AGENTS.md discovery only:** depends on working-directory ancestry
  and project Claude files; a user-level import preserves global coverage.
- **Manual mirrors or generated copies:** retain unnecessary synchronization or
  generation machinery when the client can import the canonical source itself.
- **Prose request to read AGENTS.md:** depends on model behavior and a later tool
  call; automatic imports load the rules before work starts.
- **Symlink CLAUDE.md directly to AGENTS.md:** cannot retain the Claude-only
  Agent tool rule without putting it in the universal file.

## Consequences

Universal edits have one source and no mirror-comparison dependency. The Claude
adapter remains necessary for global loading and its tool-specific rule.
Imports still consume context; they eliminate duplication in maintenance, not
the cost of the canonical instructions. After changing the import or deployment
paths, verify startup loading with `/context` in Claude Code.

This contract covers Claude Code. Claude Cowork has different restrictions on
user-scope imports and symlinks and is not validated by this setup. Custom
`CODEX_HOME` profiles still need their own link to the canonical file.

Reference: [Claude Code memory and imports](https://code.claude.com/docs/en/memory).
