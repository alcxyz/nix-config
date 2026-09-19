# ADR-0067: Explicit consumer and platform validation

**Status:** Accepted; local promotion placement amended 2026-09-19
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
   systems, and supported aliases. Main promotion and candidate input updates
   retain this evaluation alongside relevant behavioral and hygiene checks.
   Ordinary development PRs use the lightweight gate described below.
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
authorize deployments. Full checks remain available locally and mandatory for
main promotion; they are not all mandatory in the hosted development gate.

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

For main promotion and manual full validation, run all-system evaluation without
builds, followed by native flake checks,
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

## Development iteration amendment — 2026-09-10

Running the full gate on every development PR and repeating it after merge
made routine iteration too slow. Development and Nix validation already run on
`xyz`; hosted CI should not duplicate all that work before every `dev` merge.

All PRs into `dev` therefore run a lightweight gate: formatting, shell lint,
repository hygiene and focused credential-free CI tests. The gate selects its
public toolchain directly from the lock without evaluating deployment outputs
or fetching private inputs. There is no path-classification framework and no
automatic full-suite escalation for shared files.

Authors run relevant configuration and behavioral checks locally and record
results in the PR. Shared composition and input changes warrant full local
configuration and consumer validation. Main promotion retains full hosted
validation on the exact candidate; manual runs provide the same gate. Remove
post-push repeats, while preserving the input updaters' existing validation.

Alternatives considered: keeping a full gate for all shared-path changes would
still penalize common iteration; maintaining a detailed path-to-deployment graph
would introduce more policy and maintenance than this workflow needs. Relying
only on local checks for main promotion would lose an independent integration
gate. The chosen balance accepts that development CI alone does not prove the
whole deployment matrix and keeps that proof at promotion.

Tracked in [#354](https://git.alc.xyz/alcxyz/nix-config/issues/354).

## Implementation tracking

Forgejo issues and milestones own broader work. The configuration evaluation
and ordinary PR gate have passed at an exact candidate revision. The
[changed-lock updater run](https://git.alc.xyz/alcxyz/nix-config/actions/runs/50/jobs/0)
validated the standalone producer, actual consumer-selected packages, and every
exported deployment before publishing the verified lock update. This completes
the public automation rollout described by this ADR. It does not establish
runtime qualification, foreign-platform builds, or private integration
coverage.

Implementation records and broader audit tracking:

- [Configuration evaluation and PR gate](https://git.alc.xyz/alcxyz/nix-config/issues/274)
- [Consumer-context package promotion](https://git.alc.xyz/alcxyz/nix-config/issues/275)
- [Package CI failure classification](https://git.alc.xyz/alcxyz/nix-packages/issues/320)
- [Supported package/platform exports](https://git.alc.xyz/alcxyz/nix-packages/issues/321)
- [Configuration audit milestone](https://git.alc.xyz/alcxyz/nix-config/milestone/283)
- [Package audit milestone](https://git.alc.xyz/alcxyz/nix-packages/milestone/284)

## Trusted local promotion amendment — 2026-09-19

Full consumer validation and package lock publication run on a scheduled,
trusted local operator host. This placement can use the operator's ordinary
source access without projecting that access into hosted CI. The local job
fetches only the committed `dev` heads, never pull-request heads. It validates
the package repository's standalone outputs, the candidate consumer's
deployment evaluation and selected packages, and the complete configuration
gate before publishing an exact commit status receipt.

Lock publication remains fail closed. It starts only when no package update
branch is open, records the exact producer and consumer base, and repeats the
queue, producer-head, and consumer-base checks after validation immediately
before its single non-forced fast-forward push. The committed tree must equal the
validated tree. A race defers publication to a fresh run rather than reusing an
older result. An open package queue does not prevent validation of the current
committed configuration head for an unrelated main promotion.

Hosted package update PRs and their producer checks remain unchanged. Hosted
configuration PRs into `dev` retain the lightweight gate. A `dev`-to-`main`
promotion now requires the successful `ci/local-configurations` receipt on its
exact head; an absent, failed, or stale receipt fails the hosted gate. The local
job does not activate a Home Manager generation or restart services. Existing
idle-aware consumers remain responsible for later activation.
