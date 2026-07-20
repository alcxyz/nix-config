# ADR-0036: Kubernetes node power lifecycle

**Status:** Accepted
**Date:** 2026-07-12
**Applies to:** k3s nodes, `kreboot`, `koff`, `kon`

## Context

A Kubernetes node can report a successful drain while CSI detach and host-side
filesystem cleanup are still in progress. A power action can also be accepted
without actually starting a new boot. Treating either state as success risks
filesystem journal errors and returning an unchanged node to scheduling.

## Decision

Routine k3s node power operations use the shared Kubernetes-aware helpers.
Before a power action, the helper must:

1. pass cluster health checks;
2. cordon and drain application workloads unless explicitly told to skip the
   drain, while leaving the node-local Longhorn instance-manager in place;
3. wait for controller-owned workloads to settle;
4. verify that no Longhorn volume is attached to the node; and
5. verify that the host has no residual Longhorn CSI global mount or iSCSI
   session.

Before cordoning, the helper also reports any zero-disruption PDB that selects
a pod on the target node. This turns operator failover requirements—such as a
CloudNativePG primary switchover—into an immediate preflight failure instead of
spending the full drain timeout retrying an eviction that cannot succeed. Pod
capacity is evaluated in aggregate across the remaining Ready, schedulable
stable nodes after accounting for the target's evictable pods; an individually
busy node does not block maintenance when another stable node has the required
headroom.

The Longhorn health gate requires every attached or attaching volume to have a
live desired replica count of at least three before it waits for `healthy`
robustness. This is checked separately and fails immediately: changing a
StorageClass default does not update an existing Volume object, and waiting
cannot repair that policy drift while rebuild admission is deliberately
closed. Detached retained volumes do not block a node power operation because
they are outside the active attachment path; the GitOps replica-policy audit
owns their migration or retirement decision.

The Longhorn instance-manager is excluded from eviction with a Pod selector.
Its PDB remains authoritative, but does not prevent application workloads from
being drained or require healthy replica processes to be deleted before a
short host reboot. The storage-detach and host-session gates remain mandatory.

After a drain, the helper verifies that active Longhorn volumes are attached
away from the target and retain healthy replicas on at least two surviving
nodes. CloudNativePG clusters must retain a Ready primary away from the target
and enough Ready instances for one-node-down operation. Full Longhorn and
CloudNativePG health is required again after the node is returned to service.

Longhorn marks replicas on a briefly unavailable node as failed, then retains
them for `replica-replenishment-wait-interval` so they can be reused through a
delta or fast rebuild instead of replaced by a full copy. The default recovery
timeout must exceed that interval plus bounded rebuild time. Recovery output is
aggregated by the number of unhealthy attached volumes; the complete list is
printed only if the deadline expires. This keeps the helper waiting on the
real safety gate without flooding the operator while the expected reuse window
is open.

An already cordoned node is not treated as a fresh maintenance target. Another
power cycle requires `--resume-maintenance`, which verifies the existing
cordon, permits only maintenance Pods, repeats storage-detach and survivor
checks, and fails closed on ambiguity. `--check-only` runs the corresponding
fresh or resumed preflight without changing Kubernetes or host state.

For reboot, the helper records the host boot ID before the action. SSH must
become unavailable, return within the configured timeout, and expose a different
boot ID before the node can be uncordoned.

After the node reports Ready, its Kubernetes InternalIP must match the Flannel
public-IP annotation before scheduling resumes. Drain and remote reboot-command
failures leave the node cordoned for diagnosis instead of automatically
returning an uncertain node to service.

K3s nodes configure a bounded systemd reboot watchdog by default. The timeout
is host-qualified and may be disabled when that host's firmware reset path is
unvalidated or known to wedge. Runtime watchdog policy remains separate because
it also depends on host hardware validation.

Do not run a distribution-provided cluster kill-all script as a routine reboot
step on a node with attached CSI storage. It is a recovery tool, not a storage
drain mechanism.

## Consequences

A maintenance operation stops safely and leaves the node cordoned when storage
detach, SSH transition, boot identity, readiness, or workload recovery cannot be
verified. An operator must diagnose the failed gate and resume explicitly; the
helper does not reinterpret an ambiguous power state as success.
