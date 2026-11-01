# ADR-0017: k3s cluster topology for the current homelab phase

**Status:** Accepted
**Date:** 2026-04-26, updated 2026-11-02 (deployment contract, per [checklist](https://git.alc.xyz/alcxyz/nix-config/issues/753))
**Amended:** 2026-10-28
**History:** [replaced text](archive/0017-k3s-cluster-topology-history.md)
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
serve ordinary workloads. The members are `nux`, `nex`
([ADR-0034](0034-nex-as-third-k3s-server.md)) and `xev`
([ADR-0051](0051-xev-replaces-rpi0-k3s-server.md)), each with the
`server-worker` role in `inventory.nix`.

Keep interactive workstations outside the cluster
([ADR-0061](0061-retire-xyz-k3s-agent.md)). Keep network-critical resolver and
gateway control surfaces outside k3s so their availability does not depend on
cluster health: the gateway console owns the UniFi Network Application, and
Pi-hole with Unbound runs as a native resolver pair on hosts outside the
cluster ([ADR-0060](0060-gateway-owned-unifi-and-independent-dns.md)).

GitOps may manage selected desired state for an independently hosted network
service, but Kubernetes does not own that service's runtime lifecycle.

## Acceptance Contract

Topology changes must preserve control-plane quorum and independently available
name resolution. Admit a replacement server only after it is healthy and
participating in consensus; remove the replaced member through the supported
membership workflow. Verify cluster API availability, workload scheduling, and
external network services before declaring the transition complete.

### Deployment sequencing

The [deployment inventory](../../packages/nix-deploy/default.nix) puts the k3s
servers in a serial system-activation group. Before a member is activated,
its peers must pass readiness. After activation its own API must pass
`/readyz` (including etcd readiness) and its Kubernetes node must become Ready
before the next member proceeds, with a 600-second gate timeout. A failed
activation or readiness gate blocks the remaining members of that group.
This is deployment sequencing, separate from floating API endpoint eligibility.

DNS hosts form an independent serial group with a 300-second gate. Pi-hole
must answer its local name with an address and resolve a fresh random public
name through its upstream resolver. Failure leaves the next resolver running.
These groups protect quorum and name resolution while independent fleet
branches can continue and report their own failures.

## Alternatives considered

### Move the resolver service into k3s

Rejected. Name resolution is needed when the cluster is unavailable and must
remain in a separate failure domain.

### Run the network controller on a general-purpose cluster or workstation host

Rejected by [ADR-0060](0060-gateway-owned-unifi-and-independent-dns.md). The
network gateway owns that application's lifecycle.

### Retain a constrained server as a control-plane member

Rejected by [ADR-0051](0051-xev-replaces-rpi0-k3s-server.md). A stable server
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
