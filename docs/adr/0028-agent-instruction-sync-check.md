# ADR-0028: Agent instruction sync via packaged check-agent-sync tool

**Status:** Accepted
**Date:** 2026-05-02
**Applies to:** `nix-packages/tools/agent-sync-check/`, `nix-config/modules/nixos/common/pkgsets.nix`, `nix-secrets/shared/AGENTS.md`, `nix-secrets/shared/claude/CLAUDE.md`

## Context

[ADR-0022](0022-universal-agent-instructions.md) established `AGENTS.md` as
the canonical universal instruction file and kept `CLAUDE.md` as a duplicated
compatibility copy for Claude auto-loading.

That duplication is intentional for safety, but manual edits already caused
drift:

- stale tool paths existed in `AGENTS.md`
- repo-local guidance still pointed some repos at `~/.claude/CLAUDE.md`
- ADR-0022's original "one Claude-specific rule" assumption was no longer
  accurate once the explicit Claude-only delta was clarified

The question is not whether to duplicate — that is already settled by
ADR-0022. The question is how to enforce sync without making the files
generated artifacts or tying the workflow to one specific host.

## Decision

Implement a packaged CLI check, `check-agent-sync`, in `nix-packages` and
expose it through the shared home-manager package set in `nix-config`.

### Behavior

`check-agent-sync`:

- reads `~/src/infra/nix-secrets/shared/AGENTS.md` by default
- compares it with `~/src/infra/nix-secrets/shared/claude/CLAUDE.md`
- normalizes the intentional Claude-only delta
- fails if any other drift exists

The tool also accepts an explicit repo path override so it can be run against
other checkouts or future alternate layouts.

### Allowed Claude-only delta

The check permits only:

- Anthropic-specific wording in the secrets section
- The `## Agents` section
- The `Do not add a Co-Authored-By trailer` rule

Any expansion of that delta must update the tool in the same change.

### Placement

The check lives in `nix-packages`, not in `nix-secrets`, because scripts and
CLI tooling are managed as reusable packages and distributed through
`nix-config` to keep them host-agnostic.

## Alternatives Considered

**Keep a repo-local shell script in `nix-secrets`:** Rejected. It works, but
it breaks the established pattern where reusable tooling lives in
`nix-packages` and is exposed through `nix-config`.

**Generate `CLAUDE.md` from `AGENTS.md`:** Rejected for now. It would reduce
drift risk further, but it introduces a generated-artifact workflow and more
process friction than needed for the current problem.

**No automated check, rely on comments and discipline:** Rejected. Drift has
already happened once. A cheap automated check is justified.

## Consequences

- The duplicate-file safety model remains intact.
- Sync drift is detectable before or during normal editing workflows.
- Future instruction audits have a standard manual tool to reach for:
  `check-agent-sync`.
- The check is available consistently across hosts once installed via the
  normal package flow.
- The allowed Claude-only surface is now explicit and reviewable.
- This does not eliminate the option of generation later if the duplication
  cost grows.
