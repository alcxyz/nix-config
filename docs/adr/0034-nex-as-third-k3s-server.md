# ADR-0034: Add nex as the third k3s server

**Status:** Accepted
**Date:** 2026-05-05
**Applies to:** k3s control-plane topology and host roles

## Context

[ADR-0017](0017-k3s-cluster-topology.md) establishes an odd-sized,
multi-server k3s control plane so one server can be unavailable without losing
embedded-etcd quorum. A further stable machine was needed to complete that
topology and add dependable workload capacity.

Detailed host bootstrap, access, network, and recovery information is private
in accordance with
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Decision

Add `nex` as the third k3s server. It is also a schedulable worker rather than a
dedicated control-plane-only machine.

Treat initial host onboarding, cluster membership, and later stateful workload
placement as separate changes. The public configuration owns the generic host
and k3s role interfaces; private material owns the concrete bootstrap and
operational procedure.

## Alternatives Considered

**Add a worker-only node** — rejected because it would add capacity without
completing the intended control-plane quorum.

**Keep the new host outside k3s** — rejected as the steady state because the
cluster needed another stable server. A short hardware qualification period
before joining remains compatible with the decision.

**Use a control-plane-only role** — rejected because the host is suitable for
normal workloads as well as quorum duties.

## Consequences

The cluster reaches the intended three-server embedded-etcd shape and can
tolerate one server outage while quorum remains available.

The new server is a stable cluster dependency. Stateful workload changes still
require their own review after the node and control plane are healthy.
