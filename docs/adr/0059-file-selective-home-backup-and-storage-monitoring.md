# ADR-0059: File-selective home backup and host storage monitoring

**Status:** Accepted, amended 2026-08-12

**Date:** 2026-08-11

**Applies to:** `xyz`, home backup, local backup storage, host storage monitoring

## Context

The initial local `/home` protection copied the entire ZFS dataset with
snapshot replication. That was a useful migration safety net, but it retained
large rebuildable trees together with valuable user data and made file-level
exclusions impractical. It also consumed backup-pool capacity without an
explicit repository limit.

Capacity and job success were visible during manual inspection but were not
checked consistently across the workstation, backup server, and Kubernetes
nodes. A successful service start alone is insufficient evidence that scheduled
backup and mirror jobs remain current.

## Decision

Replace routine whole-dataset `/home` replication with an encrypted Restic
repository on the local backup pool. Each run creates a temporary ZFS snapshot,
bind-mounts the selected home directory read-only at a stable path, backs up that
consistent view, and destroys the temporary snapshot after Restic finishes.

Exclude rebuildable and high-churn user data by default, including caches,
downloads, trash, game installations, compatibility-layer runtimes, editor
package caches, and language package stores. These exclusions are explicit and
reviewable in host configuration. Keep seven daily, four weekly, and six
monthly snapshots. Prune and check the repository weekly, perform a full data
read monthly, and constrain repository growth with a dataset quota.

Retain the former whole-dataset replica until the new repository has completed
an initial backup, a full-data integrity check, a restore test, and a second
incremental backup. Remove the former replica only after all four gates pass.

Run a host-level monitor on storage-bearing systems. It checks expected mounts
or ZFS pools, read/write state, absolute free-space floors, required storage
services, and recent success of host backup and mirror units. Results are sent
to the existing private Healthchecks endpoint. The corresponding dead-man
checks use a 30-minute period and 15-minute grace for the 15-minute host timer.

Beszel owns percentage-based filesystem and pool-capacity history and sustained
resource alerts. Host agents report the root filesystem and explicitly selected
additional filesystems. The host-level monitor retains ZFS-specific correctness
checks because generic disk metrics do not prove pool availability, health, or
writability. Endpoint values, repository credentials, host-specific paths, and
agent credentials remain in the private configuration boundary.

The cross-repository alert ownership and reconciler policy is recorded in
GitOps ADR-048.

## Consequences

- Valuable home files retain versioned, encrypted, snapshot-consistent local
  protection without copying rebuildable bulk data.
- Individual files can be restored without recreating a ZFS dataset layout.
- Repository maintenance can reclaim unreferenced data, unlike snapshot-only
  replication chains.
- The local backup still does not protect against whole-host or site loss.
- Exclusion changes require review because an overly broad pattern can remove
  valuable data from future snapshots.
- Beszel provides capacity history and percentage alerts, while mount failures,
  unhealthy pools, absolute free-space breaches, inactive storage services,
  and stale host backup jobs continue to produce Healthchecks alerts.
- A stopped host timer or unreachable host is detected within approximately 45
  minutes rather than inheriting Healthchecks' one-day auto-provisioning period.

## Alternatives considered

### Continue whole-dataset ZFS replication

Rejected for routine `/home` protection. It preserves useful ZFS semantics but
cannot express the desired file-level boundary without reorganizing the home
directory into many datasets.

### Split `/home` into more ZFS datasets

Rejected for now. Dataset boundaries would improve selective replication but
would impose layout and mount complexity primarily to serve the backup tool.

### Back up live files directly

Rejected. A temporary ZFS snapshot gives Restic a consistent view while keeping
the file-selective repository and restore model.
