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
2. cordon and drain the node unless explicitly told to skip the drain;
3. wait for controller-owned workloads to settle;
4. verify that no Longhorn volume is attached to the node; and
5. verify that the host has no residual Longhorn CSI global mount or iSCSI
   session.

For reboot, the helper records the host boot ID before the action. SSH must
become unavailable, return within the configured timeout, and expose a different
boot ID before the node can be uncordoned.

K3s nodes configure a bounded systemd reboot watchdog. Runtime watchdog policy
is deliberately separate because it depends on host hardware validation.

Do not run a distribution-provided cluster kill-all script as a routine reboot
step on a node with attached CSI storage. It is a recovery tool, not a storage
drain mechanism.

## Consequences

A maintenance operation stops safely and leaves the node cordoned when storage
detach, SSH transition, boot identity, readiness, or workload recovery cannot be
verified. An operator must diagnose the failed gate and resume explicitly; the
helper does not reinterpret an ambiguous power state as success.
