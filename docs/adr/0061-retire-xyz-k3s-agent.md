# ADR-0061: Retire the xyz k3s agent

**Status:** Accepted

**Date:** 2026-08-26

**Applies to:** `hosts/xyz`, k3s topology, Kubernetes browser placement,
Longhorn system workloads

## Context

`xyz` joined k3s as a tainted, agent-only GPU worker so the public and private
Wolf browser singletons could fall back from `xev`. It never joined the control
plane and never stored Longhorn replicas.

The fallback nevertheless required a complete k3s, Longhorn, GPU-device-plugin,
load-balancer-speaker, worker-qualification, and browser-runtime surface on an
interactive workstation. Longhorn recurring backup and filesystem-trim jobs
also deliberately tolerated the workstation taint and could execute there.
The resulting coupling and background activity outweighed the value of browser
availability during an `xev` outage.

## Decision

Retire `xyz` from the k3s cluster and run both Kubernetes-managed Wolf browser
singletons only on `xev`.

Remove the xyz k3s agent, Longhorn attachment-node prerequisites, Kubernetes
NVIDIA runtime, browser-worker preparation, and k3s runtime mount from the
active host configuration. Keep the former ZFS runtime dataset unmounted as a
passive rollback artifact until ordinary storage housekeeping removes it; do
not back it up.

Remove the browser placement controller and worker qualification DaemonSet.
Select both browser workloads and the parked browser pilot through the
`nixbox.alc.xyz/protected-browser-worker=true` capability label, which is
assigned only to `xev`. This is an intentional single-worker boundary rather
than a promise of fallback mobility. Remove the xyz taint tolerations and node
eligibility from Longhorn, MetalLB, and the NVIDIA device plugin so cluster
infrastructure and recurring jobs remain on the three stable servers.

Nix remains the source of truth for the node-local browser package versions.
Build each versioned image and maintain a `nixbox/wolf-<browser>:current` local
alias for Kubernetes. GitOps validates the image provenance contract but does
not duplicate fast-moving Nix package versions. This prevents an ordinary host
update or post-prune image reconciliation from leaving Kubernetes pointed at a
version that no longer exists on the only qualified worker.

The host-native Kubernetes backup mirror and its ZFS-to-local-backup chain on
`xyz` remain unchanged. They do not require cluster membership.

## Consequences

- The steady-state cluster consists only of the three server/worker nodes
  `xev`, `nux`, and `nex`.
- Workstation restarts and interactive load no longer affect Kubernetes.
- Kubernetes and Longhorn system jobs can no longer execute on `xyz`.
- Loss or maintenance of `xev` makes both browser services unavailable until
  it returns or a new qualified GPU worker is deliberately introduced.
- Updating a browser package on `xev` atomically advances its local `:current`
  alias; Kubernetes does not require a matching version-only manifest change.
- Browser state remains protected by Longhorn replicas and off-volume backups;
  this decision reduces availability, not data durability.
- Backup volume, retention, and destination load are unchanged. Only xyz's
  participation as a Kubernetes execution node is removed.

## Alternatives considered

### Keep xyz and remove only the Longhorn recurring-job toleration

Rejected. It would stop backup jobs from landing on the workstation but retain
the rest of the agent, Longhorn, GPU, placement, and qualification machinery
for a fallback that is not operationally important.

### Keep xyz cordoned as a cold fallback

Rejected. A cold cluster member still carries stale-node lifecycle and runtime
maintenance costs, while uncordoning and qualification would remain a manual
recovery procedure. A future fallback should be introduced as an explicitly
supported worker.

### Retain automatic browser failover

Rejected for the current topology. The browsers are useful but do not justify
making the daily workstation part of the cluster failure and maintenance
domain.
