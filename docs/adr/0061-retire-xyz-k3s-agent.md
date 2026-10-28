# ADR-0061: Retire the xyz k3s agent

**Status:** Accepted

**Date:** 2026-08-26

**Amended:** 2026-10-28

**History:** [replaced text](archive/0061-retire-xyz-k3s-agent-history.md)

**Supersedes:** [ADR-0057](archive/0057-kubernetes-managed-protected-browser-mobility.md)
(two-worker Wolf browser placement with `xyz` as preferred worker and fallback)

**Applies to:** `hosts/xyz`, `hosts/xev`, k3s worker topology, public and
protected browser placement, and cluster storage workloads

## Context

`xyz` joined k3s as a tainted, agent-only GPU worker to provide fallback
capacity for protected browser workloads. It did not participate in the control
plane or hold persistent cluster-storage replicas.

Maintaining that fallback nevertheless required the full worker, storage-client,
GPU, networking, qualification, and browser runtime surface on an interactive
workstation. The operational coupling and background activity outweighed the
availability benefit.

Detailed node labels, runtime mounts, image aliases, storage paths, backup
topology, and removal or recovery procedures are private in accordance with
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Decision

Retire `xyz` from k3s. Run the browser workloads on one explicitly qualified
stable GPU worker, `xev`, accepting that worker as a single availability
boundary. Remove workstation eligibility from cluster system workloads and
remove the placement automation that existed only to support fallback to
`xyz`.

### Browser placement on xev

Run the public and private (protected) Wolf coordinators as independent
Kubernetes singletons pinned to `xev`, the only node carrying the
protected-browser worker label. Each keeps its separate identity, namespace,
Service, Longhorn RWO volume, backup identity, and trust boundary, as
[ADR-0056](0056-containerized-remote-browser-streaming.md) requires. Each is a
one-replica Deployment with a `Recreate` rollout, so two coordinators never run
against the same state, and rollback selects one authoritative copy rather than
merging two writable browser trees.

Each coordinator is exposed through its own LAN `LoadBalancer` Service. A
stable VIP follows the ready singleton endpoint, and private DNS gives that VIP
a durable client name; clients do not carry worker addresses.

`xev` advertises two time-sliced GPU shares on its one physical GPU. Each
coordinator requests one share, and requests larger than one are rejected. A
third Kubernetes GPU workload is not admitted without a new capacity decision.
Time-slicing is scheduler overcommit, not partitioning: it does not isolate
VRAM, faults, or performance, so concurrent sessions may degrade one another.
Protected Wolf has the higher scheduling priority if the shares are exhausted.

There is no alternate Wolf worker, placement controller, worker qualification
DaemonSet, or automatic failover or failback. Loss of `xev` makes both
browsers unavailable until it returns. Longhorn replication (three replicas on
the stable storage nodes) and recurring off-volume backups protect their
persistent state; replication is not a backup.

Each coordinator has one expandable Longhorn RWO volume for its Wolf
configuration, pairings, and browser homes: 10 GiB for the protected
coordinator and 5 GiB for the public one. Container images and build caches
stay outside both volumes. Expand a filesystem before sustained usage exceeds
roughly 70 to 75 percent.

Wolf keeps its node-local Docker runner: each supervisor starts its coordinator
and browser containers through `xev`'s Docker API. This broad capability is an
explicit trusted-host boundary:

- only the public-browser and private-browser namespaces may run their
  respective supervisors;
- the workload is restricted to declared protected-browser workers, now `xev`;
- the Docker socket and host devices are never exposed through a network
  service;
- the supervisor removes only its known coordinator and runner containers; and
- a later native runner may supersede this boundary in a separate ADR.

Wolf passes browser home directories to sibling Docker containers as host bind
mounts, so a versioned launcher resolves the volume mount belonging to its own
Pod and passes that node-visible path as Wolf's host application-state folder.
It derives the path from the Pod identity and mounted volume, validates that it
resolves to the expected Longhorn filesystem, and fails closed instead of
falling back to node-local state. GitOps does not embed a transient kubelet
mount path.

`xev` prepares the pinned Wolf and browser images, separate public and
protected runtime roots, NVIDIA CDI support, virtual-input devices, and both
isolated Moonlight port sets (`hosts/xev/configuration.nix`,
`modules/nixos/services/wolf-streaming/default.nix`,
`modules/nixos/services/wolf-streaming/worker-runtime.nix` and
`modules/nixos/virtualisation/k3s/nvidia-runtime.nix`). Worker preparation does
not start either coordinator outside its Kubernetes supervisor.

### Artifacts and backups

Keep Nix as the source of truth for browser inputs, build contexts, and runtime
behavior. Under GitOps ADR-052 and
[nix-config issue #372](https://git.alc.xyz/alcxyz/nix-config/issues/372),
which replace the original node-local image builds and mutable aliases, trusted
Forgejo CI publishes immutable registry artifacts and hosts and GitOps consume
them. Issue #372 records completed registry adoption through the producer and
consumer changes, including
[PR #377](https://git.alc.xyz/alcxyz/nix-config/pulls/377).

Host-native backup responsibilities remain independent of Kubernetes
membership. Their concrete storage and recovery design belongs in the private
operational record.

## Acceptance Contract

Before completing retirement, verify that no control-plane membership,
persistent cluster replicas, or required system workloads depend on `xyz`.
Confirm protected browsers start and retain their expected input and persistence
behavior on the qualified worker, and confirm cluster system workloads remain
eligible on stable nodes. Retire passive rollback artifacts through ordinary storage housekeeping.

Artifact-ownership acceptance requires immutable images to be
published by trusted CI, consumed by the host and GitOps definitions, deployed,
and checked against the declared browser contract. Issue #372 records the
completed checks and the separate streaming-qualification limitation: that
recorded acceptance did not include end-to-end Moonlight streaming
qualification.

## Consequences

- Interactive workstation restarts and load no longer affect Kubernetes.
- Cluster workloads can no longer execute on `xyz`.
- Loss or maintenance of `xev`, the sole qualified GPU worker, interrupts both
  browser services until it returns or another worker is deliberately
  qualified.
- Both coordinators share one physical GPU, so one browser session or a
  host-native GPU workload can degrade the other.
- Browser persistence and host-native backups remain separate from worker
  membership.
- Artifact distribution follows the registry contract; its recorded acceptance
  does not imply new end-to-end streaming qualification.

## Alternatives considered

### Keep xyz and remove only background storage jobs

Rejected. This would retain most worker, GPU, networking, placement, and
qualification machinery for a fallback that is not operationally important.

### Keep xyz cordoned as a cold fallback

Rejected. A cold member still creates stale-node and runtime maintenance work.
A future fallback should be introduced as an explicitly supported worker.

### Retain automatic browser failover

Rejected for the current topology. Browser availability does not justify making
an interactive workstation part of the cluster failure and maintenance domain.
