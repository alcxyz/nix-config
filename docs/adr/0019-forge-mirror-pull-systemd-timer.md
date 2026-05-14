# ADR-0019: Periodic Forgejo/GitHub drift audit via forge-mirror-audit systemd timer

**Status:** Accepted
**Date:** 2026-04-26
**Applies to:** `modules/nixos/services/forge-mirror-audit/`, `hosts/nux/configuration.nix`

## Context

With Forgejo now acting as the canonical Git remote (see gitops ADR-005), the old GitHub-to-Forgejo pull timer is no longer the right safety net.

The operational need remains, but the purpose changed:

- detect branch ref drift between Forgejo and GitHub
- detect default branch drift
- detect unhealthy or missing Forgejo push mirrors
- detect missing Forgejo `main` protection

The timer should report these problems, not automatically rewrite the canonical host.

## Decision

Run a NixOS systemd timer on nux that executes `forge-mirror audit` every 8 hours. The service:

- authenticates to Forgejo with the system token from nix-secrets
- authenticates to GitHub with the read-only mirror PAT from nix-secrets
- talks to Forgejo through the local Traefik route (`http://git.local`) to avoid Cloudflare as a dependency for auditing
- compares branch refs, default branches, push mirror health, and Forgejo `main` protection
- exits non-zero on drift or policy violations so failures are visible in journald and systemd state

Credentials are supplied through private sops wiring. Git is injected into PATH via `lib.makeBinPath`.

## Alternatives Considered

**Home-manager user service** — simpler secret wiring (user-level sops), but less reliable for unattended cron (depends on user session).

**Forgejo Actions cron workflow** — rejected because it depends on the Forgejo runner being healthy. The audit should remain independent infrastructure.

**Keep the old pull timer** — rejected because it silently mutates Forgejo and hides workflow drift instead of surfacing it.

## Consequences

- Drift is surfaced within 8 hours instead of being silently papered over.
- Requires private mirror credentials with Contents + Metadata read-only access to all mirrored repos.
- `git.local` must resolve on nux (added to `networking.hosts`).
- Timer logs are in journald under `forge-mirror-audit` for debugging.
