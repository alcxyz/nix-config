# ADR-0061: Retire the xyz k3s agent

**Status:** Accepted

**Date:** 2026-08-26

**Applies to:** `hosts/xyz`, k3s worker topology, protected browser placement,
and cluster storage workloads

**Artifact ownership amendment:** GitOps ADR-052 and
[nix-config issue #372](https://git.alc.xyz/alcxyz/nix-config/issues/372)
supersede the original node-local image build and mutable alias ownership.
Issue #372 records completed registry adoption through the producer and consumer
changes, including [PR #377](https://git.alc.xyz/alcxyz/nix-config/pulls/377).
Nix owns browser inputs, build contexts and runtime behavior; trusted Forgejo CI
publishes immutable registry artifacts for hosts and GitOps to consume. The
worker, storage, input and placement decisions here remain active. That recorded
acceptance did not include end-to-end Moonlight streaming qualification.

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

Retire `xyz` from k3s. Run the protected browser workloads on one explicitly
qualified stable GPU worker, accepting that worker as a single availability
boundary. Remove workstation eligibility from cluster system workloads and
remove the placement automation that existed only to support fallback to
`xyz`.

Keep Nix as the source of truth for browser inputs, build contexts, and runtime
behavior. Under the artifact-ownership amendment above, trusted CI publishes
immutable images and hosts and GitOps consume them.

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
completed checks and the separate streaming-qualification limitation.

## Consequences

- Interactive workstation restarts and load no longer affect Kubernetes.
- Cluster workloads can no longer execute on `xyz`.
- Loss or maintenance of the sole qualified GPU worker interrupts the protected
  browser services until it returns or another worker is deliberately qualified.
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
