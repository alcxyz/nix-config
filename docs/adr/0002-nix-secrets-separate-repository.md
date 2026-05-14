# ADR-0002: Keep private infrastructure material outside nix-config

**Status:** Accepted, amended 2026-05-14
**Date:** 2026-04-18
**Applies to:** `flake.nix`, `modules/nixos/common/default.nix`, private runbooks

## Context

Nix configurations need to reference private material at build and activation
time. Some of that material is encrypted SOPS YAML, but the same repository
boundary is also needed for private host bootstrap notes, recovery procedures,
and private modules that should not be documented in the public config.

Access control differs: this config repo benefits from being shareable as a
reference, while private infrastructure material should be accessible only to
trusted operators and machines that need it.

## Decision

Private infrastructure material lives in a separate private Git repository
(`alcxyz/nix-secrets`), imported as a flake input. It may expose flake outputs
for private path metadata, helper packages, runbook references, and private
NixOS/Home Manager modules.

The public repo may reference stable private module and path outputs, but should
not duplicate private runbook details, secret metadata beyond what is required
for declarative wiring, or sensitive operational assumptions.

## Alternatives Considered

- **Inline secrets directory in this repo** - rejected. It would prevent sharing
  this config publicly and expose private metadata.
- **agenix-style secrets committed to the config repo** - rejected. The
  separation of access control between config and private material is lost.
- **HTTPS URL for nix-secrets** - rejected. SSH is cleaner and consistent with
  how the machines already authenticate to private Git.
- **Keep nix-secrets as YAML-only forever** - rejected. Private modules and
  runbooks need the same access boundary as encrypted secret files.

## Consequences

- This repo can be shared or published with less private operational context.
- Deployments require SSH access to `nix-secrets`.
- `flake.lock` pins `nix-secrets` to a specific commit; private material changes
  require a lock update to take effect in dependent builds.
- Agents must never add SOPS YAML files, secret content, private runbooks, or
  sensitive host bootstrap detail to this repository.
