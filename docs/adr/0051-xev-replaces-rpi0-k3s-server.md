# ADR-0051: xev replaces rpi0 as a k3s server

**Status:** Accepted (amended by ADR-0060)
**Date:** 2026-05-31
**Applies to:** k3s control-plane membership and independent network services

## Context

One early control-plane member combined the cluster server role with independent
network services on a resource-constrained host. Sustaining the operating
system, consensus state, and routine cluster maintenance there created avoidable
capacity and recovery pressure. A more capable stable machine was already
qualified for normal cluster workloads.

Concrete membership, addressing, bootstrap, snapshot, removal, and recovery
procedures are private in accordance with
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Decision

Replace the resource-constrained k3s server with `xev` in the steady-state
embedded-etcd control plane. `xev` carries both server and worker roles. The
replaced host leaves Kubernetes and continues only its independent host-native
network-service role.

The change preserves an odd-member control plane and one-server failure
tolerance. [ADR-0060](0060-gateway-owned-unifi-and-independent-dns.md) later
established the final ownership of the independent resolver and gateway
services; those services remain outside Kubernetes.

## Acceptance Contract

Before removing the old member, verify consensus health, create and verify a
current recovery point, admit the replacement, and confirm that it participates
in consensus. Remove the old member through the supported cluster workflow.
Then verify node readiness, API availability through the stable endpoint,
control-plane failure tolerance, independent network services, and affected
host service health.

## Alternatives considered

### Keep the constrained host in the control plane

Rejected because recurring capacity pressure and its independent network role
make it a poor steady-state consensus dependency.

### Keep xev as a worker only

Rejected because worker capacity alone would not replace the constrained
control-plane member or preserve the intended quorum shape.

## Consequences

- The cluster retains the same control-plane size and one-server failure
  tolerance on stable machines.
- The replaced host no longer carries consensus state or cluster maintenance
  load.
- `xev` becomes a stable control-plane dependency as well as a workload host.
- Network-critical services remain independent of Kubernetes availability.
