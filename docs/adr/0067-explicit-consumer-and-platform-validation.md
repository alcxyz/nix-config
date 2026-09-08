# ADR-0067: Explicit consumer and platform validation

**Status:** Accepted; automation rollout pending
**Date:** 2026-09-07
**Accepted:** 2026-09-08
**Applies to:** `flake/`, Forgejo checks, package input promotion, cross-repository validation

## Context

The September 2026 repository audit found that the existing flake checks can
pass while a Home Manager activation derivation fails to evaluate. It also
found that standalone package validation and consumer validation can evaluate
different derivations because the consuming flake overrides package inputs.

ADR-0007 retains reusable packages in a separate repository. ADR-0043 retains
explicit composition and calls for useful local and CI checks. Those decisions
need an explicit definition of what each validation layer proves.

## Decision

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

This decision does not change the existing Wolf input acceptance contract or
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

## Execution contract

Run all-system evaluation without builds, followed by native flake checks,
against the exact candidate checkout and without updating its lock. The
configuration-evaluation check forces every exported deployment, including
Home Manager aliases; its synthetic regression test rejects a broken Home
Manager output even when ordinary flake schema checks would overlook it.

Package promotion retains standalone producer validation and separately
validates packages selected by the candidate consumer and its deployment
outputs. Record the consumer source revision and lock digest together with the
producer revision, since an uncommitted candidate lock is not
identified by the source commit alone.

Ordinary PR automation uses the `pull_request` event and validates the PR head,
not an implicit merge reference. Contributions requiring maintainer staging
must fail the full-validation prerequisite clearly. Private source-access
provisioning and operational diagnostics belong in the private repository;
public CI must not publish private evaluation diagnostics as artifacts or logs.
Provisioning is a rollout prerequisite, separate from accepting this evaluation
contract. See the [validation guide](../validation.md).

## Implementation tracking

Forgejo issues and milestones own execution status. Acceptance of this contract does not mark the following implementation work
complete. The configuration evaluation helper already covers all exported
deployments. The ordinary PR workflow must pass on an exact candidate revision
before its rollout is complete; unavailable source access is a failed
prerequisite, never a skipped evaluation reported as success.

- [Configuration evaluation and PR gate](https://git.alc.xyz/alcxyz/nix-config/issues/274)
- [Consumer-context package promotion](https://git.alc.xyz/alcxyz/nix-config/issues/275)
- [Package CI failure classification](https://git.alc.xyz/alcxyz/nix-packages/issues/320)
- [Supported package/platform exports](https://git.alc.xyz/alcxyz/nix-packages/issues/321)
- [Configuration audit milestone](https://git.alc.xyz/alcxyz/nix-config/milestone/283)
- [Package audit milestone](https://git.alc.xyz/alcxyz/nix-packages/milestone/284)
