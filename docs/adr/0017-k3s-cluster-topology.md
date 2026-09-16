# ADR-0017: k3s cluster topology for the current homelab phase

**Status:** Accepted (amended by ADR-0051, ADR-0060, and ADR-0061)
**Date:** 2026-04-26
**Updated:** 2026-08-20
**Applies to:** stable k3s servers, workstation agents, independent network services

## Context

Application workloads need a small highly available k3s control plane. Network
services required to reach or diagnose the cluster must remain usable when the
cluster is unavailable. Interactive workstations also have a different restart,
maintenance, and load profile from stable servers.

Detailed node inventory, addressing, bootstrap, migration, and recovery
procedures are private in accordance with
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Decision

Run a three-member embedded-etcd control plane on stable machines that also
serve ordinary workloads. Keep interactive workstations outside the steady-state
cluster. Keep network-critical resolver and gateway control surfaces outside
k3s so their availability does not depend on cluster health.

GitOps may manage selected desired state for an independently hosted network
service, but Kubernetes does not own that service's runtime lifecycle.

[ADR-0051](0051-xev-replaces-rpi0-k3s-server.md) records the control-plane
member replacement, [ADR-0060](0060-gateway-owned-unifi-and-independent-dns.md)
records the network-service ownership decision, and
[ADR-0061](0061-retire-xyz-k3s-agent.md) records the retirement of the
workstation agent.

## Acceptance Contract

Topology changes must preserve control-plane quorum and independently available
name resolution. Admit a replacement server only after it is healthy and
participating in consensus; remove the replaced member through the supported
membership workflow. Verify cluster API availability, workload scheduling, and
external network services before declaring the transition complete.

## Alternatives considered

### Move the resolver service into k3s

Rejected. Name resolution is needed when the cluster is unavailable and must
remain in a separate failure domain.

### Run the network controller on a general-purpose cluster or workstation host

Superseded by [ADR-0060](0060-gateway-owned-unifi-and-independent-dns.md). The
network gateway owns that application's lifecycle.

### Retain a constrained server as a control-plane member

Superseded by [ADR-0051](0051-xev-replaces-rpi0-k3s-server.md). A stable server
with greater resource headroom is a better control-plane dependency.

### Count an interactive workstation as part of the cluster

Rejected by [ADR-0061](0061-retire-xyz-k3s-agent.md). Its restart, load, and
maintenance profile creates more operational coupling than its fallback
capacity justifies.

### Add worker capacity without completing the intended control plane

Rejected. The additional stable machine was selected to complete the
odd-member control-plane design, rather than only add worker capacity.

## Consequences

- The embedded-etcd control plane tolerates the loss of one server.
- Resolver and gateway services remain available independently of cluster
  health.
- Stable machines carry both control-plane and workload responsibilities.
- Interactive workstation maintenance does not affect Kubernetes membership.
