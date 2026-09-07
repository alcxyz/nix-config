# ADR-0067: Explicit consumer and platform validation

**Status:** Proposed
**Date:** 2026-09-07
**Applies to:** `flake/`, Forgejo checks, package input promotion, cross-repository validation

## Context

The September 2026 repository audit found that the existing flake checks can
pass while a Home Manager activation derivation fails to evaluate. It also
found that standalone package validation and consumer validation can evaluate
different derivations because the consuming flake overrides package inputs.

ADR-0007 retains reusable packages in a separate repository. ADR-0043 retains
explicit composition and calls for useful local and CI checks. Those decisions
need an explicit definition of what each validation layer proves.

## Proposed decision

Keep the existing repository and module boundaries, and validate both sides of
the package/configuration integration:

1. The package repository declares supported package/system combinations.
   An evaluation failure on an advertised platform is a failed check, not a
   signal to silently fall back to metadata from another platform. Shared
   dependency and export changes trigger the appropriate complete matrix.
2. The configuration repository derives evaluation targets from inventory and
   explicitly forces NixOS toplevels, Home Manager activation packages, Darwin
   systems, and supported aliases. Ordinary PRs and candidate input promotions
   run this evaluation alongside the existing behavioral and hygiene checks.
3. Package input promotion validates the actual derivations selected by the
   candidate consumer lock, in addition to standalone producer checks. Record
   the tested revision combination; equal package versions alone are not proof
   of equal build inputs.
4. Keep evaluation, native package builds, and runtime qualification distinct.
   A successful evaluation is not a completed deployment or hardware test.
   Full host builds remain targeted to the changes and platforms that need
   them rather than becoming mandatory for every documentation-only PR.
5. Private integration checks use synthetic configuration and run in the
   private repository. Public checks and documentation contain generic
   interfaces and redacted evidence only.

This proposal does not change the existing Wolf input acceptance contract or
authorize deployments. Existing checks remain in place while missing coverage
is added.

## Alternatives considered

- **Use only `nix flake check --all-systems`.** Insufficient because custom
  configuration outputs still need explicit evaluation coverage.
- **Use only standalone package builds.** Insufficient because the consumer
  can override the package dependency graph and select different derivations.
- **Build every complete host closure on every change.** Adds substantial
  cost and platform requirements while still leaving runtime behavior untested.
  Use comprehensive evaluation plus targeted native builds and behavioral tests.
- **Replace the repository framework.** Does not address the demonstrated
  coverage gaps and conflicts with ADR-0043's incremental direction.

## Consequences

The gate has a clear producer/consumer contract and catches platform-selection
errors before activation. The complete evaluation matrix adds evaluation cost,
and selected native builds still require suitable builders. Runtime acceptance
remains explicit for changes that depend on input devices, storage, or services.

## Implementation tracking

Forgejo issues and milestones own execution status. This ADR remains proposed
until reviewed; it does not mark the following work complete.

- [Configuration evaluation and PR gate](https://git.alc.xyz/alcxyz/nix-config/issues/274)
- [Consumer-context package promotion](https://git.alc.xyz/alcxyz/nix-config/issues/275)
- [Package CI failure classification](https://git.alc.xyz/alcxyz/nix-packages/issues/320)
- [Supported package/platform exports](https://git.alc.xyz/alcxyz/nix-packages/issues/321)
- [Configuration audit milestone](https://git.alc.xyz/alcxyz/nix-config/milestone/283)
- [Package audit milestone](https://git.alc.xyz/alcxyz/nix-packages/milestone/284)
