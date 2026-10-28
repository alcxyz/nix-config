# ADR-0051: xev replaces rpi0 as a k3s server

**Status:** Accepted
**Date:** 2026-05-31
**Amended:** 2026-10-28
**History:** [replaced text](archive/0051-xev-replaces-rpi0-k3s-server-history.md)
**Applies to:** k3s control-plane membership and independent network services

## Context

One early control-plane member, `rpi0`, combined the cluster server role with
independent network services on a resource-constrained host. Sustaining the
operating system, consensus state, and routine cluster maintenance there
created avoidable capacity and recovery pressure. A more capable stable
machine, `xev`, was already qualified for normal cluster workloads.

Concrete membership, addressing, bootstrap, snapshot, removal, and recovery
procedures are private in accordance with
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Decision

`xev` replaces the resource-constrained `rpi0` in the steady-state
embedded-etcd control plane and carries both server and worker roles
(`server-worker` in `inventory.nix`). `rpi0` is outside Kubernetes
(`k8sRole = null`) and carries no consensus state.

The control plane keeps an odd member count and one-server failure tolerance.
`rpi0` remains one of the two native resolver hosts, outside Kubernetes, under
[ADR-0060](0060-gateway-owned-unifi-and-independent-dns.md), which also places
the gateway services outside the cluster.

## Acceptance Contract

Before removing or replacing a k3s server member, verify consensus health and
create and verify a current recovery point. Admit any replacement and confirm
that it participates in consensus, then remove the old member through the
supported cluster workflow. Afterwards verify node readiness, API availability
through the stable endpoint, control-plane failure tolerance, independent
network services, and affected host service health. These safeguards apply in
addition to the topology contract in
[ADR-0017](0017-k3s-cluster-topology.md).

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
- `rpi0` no longer carries consensus state or cluster maintenance load.
- `xev` is a stable control-plane dependency as well as a workload host.
- Network-critical services remain independent of Kubernetes availability.
