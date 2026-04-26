# ADR-0022: Universal Agent Instructions via AGENTS.md

**Status:** Accepted
**Date:** 2026-04-26
**Applies to:** `nix-secrets/shared/AGENTS.md`, `nix-secrets/shared/claude/CLAUDE.md`, `nix-config/users/alc/common.nix`

## Context

AI agent instructions (ADR conventions, secrets handling, tool documentation,
commit style) were maintained exclusively in `~/.claude/CLAUDE.md`, which is
Claude Code-specific. This created vendor lock-in: switching to or adding
another AI agent (Cursor, Copilot, Codex, local models) would require
duplicating all conventions into that tool's format.

The instructions include safety-critical rules (never read secrets, never
print env vars) that must be respected by any agent, not just Claude.

## Decision

Maintain a universal `AGENTS.md` file as the source of truth for all agent
conventions, deployed to `~/AGENTS.md` via home-manager. Keep `CLAUDE.md`
as a parallel copy with Claude-specific additions.

### File structure

```
nix-secrets/shared/
├── AGENTS.md              ← source of truth, universal
└── claude/CLAUDE.md       ← parallel copy + Claude-specific rules
```

### Deployment (home-manager)

```nix
home.file."AGENTS.md".source = mkOutOfStoreSymlink
  "${homeDirectory}/nix/nix-secrets/shared/AGENTS.md";

home.file.".claude/CLAUDE.md".source = mkOutOfStoreSymlink
  "${homeDirectory}/nix/nix-secrets/shared/claude/CLAUDE.md";
```

### Sync rules

- AGENTS.md is the canonical source. Edits go there first.
- CLAUDE.md duplicates all universal content plus one Claude-specific rule
  (no Co-Authored-By trailer).
- The secrets section is intentionally duplicated in CLAUDE.md because it is
  auto-loaded into Claude's context — a reference to an external file would
  require an explicit read action, creating a window where safety rules are
  not yet loaded.

## Alternatives Considered

**CLAUDE.md references AGENTS.md ("read ~/AGENTS.md"):** Rejected. Claude
Code auto-loads CLAUDE.md but would need to actively read AGENTS.md,
wasting tokens every conversation and risking a window before safety rules
are loaded.

**AGENTS.md only, no CLAUDE.md:** Not possible. Claude Code only auto-loads
files named CLAUDE.md. Without it, no instructions are loaded automatically.

**Build-time inclusion (Nix templating):** The files use `mkOutOfStoreSymlink`
for live editing. Build-time composition would require a rebuild to change
instructions, adding friction to iteration.

**Keep everything in CLAUDE.md, create AGENTS.md as export:** Would make
CLAUDE.md the source of truth and AGENTS.md a derived artifact, inverting
the intended relationship where universal rules come first.

## Consequences

- Any AI agent that reads `~/AGENTS.md` or per-repo `AGENTS.md` gets the
  full conventions without Claude-specific tooling.
- Two files must be kept in sync. Both live in nix-secrets with comments
  noting the relationship, reducing drift risk.
- The secrets section exists in both files — accepted duplication for safety.
- Adding a new agent tool only requires pointing it at `~/AGENTS.md`.
- Per-repo AGENTS.md files can be added incrementally as repos adopt the
  convention.
