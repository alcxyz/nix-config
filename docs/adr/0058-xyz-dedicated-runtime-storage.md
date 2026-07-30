# ADR-0058: Dedicated xyz runtime storage

**Status:** Accepted, staged

**Date:** 2026-07-30

**Applies to:** `xyz`, Docker, k3s, Steam-headless, ZFS, backups

## Context

`xyz` has rebuildable container runtime data and durable Steam-headless state on
the encrypted system pool. Growth in those paths competes with the workstation
root and home datasets. The host also has a separate SSD available for this
work, while game installations already have their own storage boundary.

`xyz` is an opportunistic Kubernetes GPU worker. Moving runtime data must not
turn it into a Longhorn replica-storage node or make normal workstation
restarts depend on storage reconstruction.

## Decision

Use a dedicated, single-device, natively encrypted ZFS pool for node-local
container storage on `xyz`.

Create separate datasets for:

- Docker runtime data;
- k3s agent runtime data; and
- durable Steam-headless application state.

Mount the datasets at their existing service-native `/var/lib` paths. Apply
independent quotas so Docker or k3s growth cannot consume space reserved for
Steam-headless, and reserve a bounded amount of capacity for Steam-headless.
Keep game installations on the existing game-library storage.

Treat Docker and k3s directories as rebuildable runtime data. Do not include
them in application-state backups. Continue treating Steam-headless as durable
app state: retain automatic snapshots and replicate it to the encrypted local
backup pool alongside the other selected appstate datasets.

Keep Longhorn replica scheduling disabled on `xyz`. The new pool is not a
Longhorn disk and does not change the node's opportunistic lifecycle.

Before migration, take fresh source snapshots and complete the existing
appstate backup. Preserve the former source datasets as a bounded rollback
point until the new mounts, services, backup replication, and a restore check
have passed. Detailed device identities, encryption-key handling, migration
commands, and recovery steps remain in the private runbook established by
[ADR-0048](0048-xyz-small-nvme-retirement.md).

The local backup protects against loss of the new runtime SSD but remains on
the same host. Whole-host and site-loss protection is a separate off-host
backup requirement; do not describe the local replica as satisfying it.

## Consequences

- Docker, k3s, and Steam-headless growth no longer consumes workstation root
  pool capacity.
- Workloads keep their established paths and need no path-specific changes.
- Quotas bound runtime growth and preserve capacity for durable app state.
- Failure of the runtime SSD removes rebuildable Docker and k3s state, while
  Steam-headless can be restored from independent encrypted storage.
- The single-device pool is not redundant. Snapshots help with logical
  mistakes, while replication is required for device loss.
- Restarting `xyz` does not create Longhorn replica rebuild work.
- Pool unlock material and operational recovery procedures remain private.

## Alternatives considered

### Put all data on the game-library filesystem

Rejected. Game installations are bulk, replaceable data with a different
capacity and recovery policy from container runtime and application state.

### Add the SSD as a Longhorn disk

Rejected. It would make an interactive workstation part of the durable replica
set and work against its restart and maintenance requirements.

### Use one shared filesystem without dataset quotas

Rejected. A runaway image cache or agent runtime could consume the capacity
needed by Steam-headless state.

### Back up Docker and k3s runtime directories

Rejected. Images, containers, and agent runtime state are recreated from
declarative configuration. Backing them up would add large, inconsistent
copies without improving durable-state recovery.

## Tracking

- Forgejo milestone: **XYZ dedicated runtime storage**
- Issue #191: runtime and Steam-headless migration
- Issue #192: protected-browser image catalog and regression qualification
- Issue #193: off-host recovery for durable container app state

The public issues contain only non-sensitive acceptance criteria; the private
runbook contains host-specific execution and rollback details.
