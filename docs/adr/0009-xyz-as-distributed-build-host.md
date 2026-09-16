# ADR-0009: Distributed build roles and explicit client opt-in

**Status:** Accepted, redacted
**Date:** 2026-04-18
**Applies to:** distributed-build client interface, build-capable hosts, deploy inventory, Darwin builder support

## Context

The fleet contains multiple architectures and machines with different build
capacity. Some targets need remote or emulated builds, while deployment must
remain possible when a normal builder or operator host is unavailable.

## Decision

Distributed builds are an explicit client capability through
`alc.distributedBuildClient`. Participating clients use a primary and fallback
Linux builder set with declared priorities. Build-capable hosts provide the
configured architectures and Nix features. Cross-architecture support uses
emulation where native capacity is unavailable.

The named private `nixosModules.distributedBuildClientPolicy` module owns the
existing client option schema, concrete builder selection and priorities, and
dedicated build-identity deployment. The public common module imports it;
server role alone does not enable build-client credentials. Storage,
authorization, host mappings and rotation procedures remain private policy.

Deployment tooling consumes the versioned inventory interface, checks target
reachability before remote work, and supports a local-operator fallback.
Concrete endpoints, operator procedures and recovery assumptions are documented
in the private distributed-build runbook. Reusable command behavior and tests
remain in `nix-packages`.

The Darwin Linux builder remains a cold-standby coordination path, outside normal
fleet build capacity. Expanding its supported Linux architectures requires
separate validation.

## Alternatives Considered

- **Native builds everywhere:** impractical for low-capacity targets.
- **A separate build farm:** more operational overhead than the current fleet
  requires.
- **Cross-compilation instead of emulation:** potentially faster, but with more
  package compatibility constraints.
- **Public concrete authentication policy:** conflicts with the accepted
  private-material boundary; a named private module preserves declarative
  integration without duplicating those defaults.

## Consequences

Low-capacity and cross-architecture targets can offload builds without making
every server a credential-bearing client. Loss of a preferred builder reduces
capacity without changing the declared client contract. Public configuration
remains reviewable while access policy and recovery procedures have a private
owner.

Source extraction preserves generated build machines, secret projections and
activation-related configuration. It does not activate clients or change access.
Current-tree redaction does not erase earlier published versions; historical
source and tracker review remain in the private audit.

## Follow-up

- [#78](https://git.alc.xyz/alcxyz/nix-config/issues/78): enable and validate
  x86_64-linux support in the Darwin Linux builder.
