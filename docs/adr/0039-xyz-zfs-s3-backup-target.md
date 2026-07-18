# ADR-0039: xyz ZFS-backed S3 target for cluster backups

**Status:** Superseded by ADR-0052
**Date:** 2026-05-06
**Applies to:** `hosts/xyz`, `modules/nixos/services/k8s-backup-s3`, k3s backup posture

## Context

Longhorn now carries most Kubernetes application PVCs. Longhorn replication
improves node mobility inside the cluster, but it is not a backup. Backing up
Longhorn to the in-cluster RustFS deployment would create a circular dependency:
the backup target itself depends on k3s and Longhorn being healthy.

`xyz` has encrypted ZFS storage outside the k3s storage dependency path. The
original decision placed the bounded backup target on `ypool`. The storage
rebuild consolidates the old `zpool` and `ypool` roles into one encrypted
mirror-vdev pool named `tank`.

Database backup automation is intentionally deferred until the database topology
is revisited. The cluster still has a per-application database pattern, while
ADR-0024 proposes a shared Postgres cluster. Adding per-app dump jobs now would
lock in the current topology and multiply backup lifecycle work.

## Decision

Run a host-level RustFS S3 endpoint on `xyz` for cluster backups, backed by a
dedicated ZFS dataset:

- dataset: `tank/k8s-backups`
- mountpoint: `/tank/k8s-backups`
- object data: `/tank/k8s-backups/rustfs`
- quota: `1T`
- API: `192.168.1.10:9100`
- console: `127.0.0.1:9101`

The service is managed by `services.k8s-backup-s3`. It creates the ZFS dataset
if missing, enforces the quota, and prepares RustFS credentials from sops-nix.
The RustFS binary comes from the official `github:rustfs/rustfs` Nix flake so
the host backup target uses the same object-store implementation as k3s.
Bucket creation and Longhorn backup-target wiring happen as the next GitOps step
after the host service is deployed.

The host-level S3 target is backup-only. In-cluster RustFS remains the
application object store for Forgejo, Nextcloud, Linkwarden, and similar
workloads.

## Space Policy

The hard cap is the ZFS dataset quota, initially `1T`. Backup schedules must be
configured so normal retention remains well below that cap. If the dataset fills,
backups should fail loudly instead of consuming the rest of `tank`.

Longhorn recurring backup retention should be conservative at first:

- short retention for low-risk PVC validation
- longer retention only for critical PVCs after restore testing
- no unlimited recurring backup schedules

## Deferred Work

Do not add database dump CronJobs until the database consolidation decision is
made. The next database decision should resolve whether the cluster continues
with per-app databases or moves to a shared/operator-managed database layer.

After that decision, add app-aware backup jobs for PostgreSQL, MariaDB, and
application exports, writing to the host-level S3 target.

## Consequences

- **Easier:** Longhorn can back up to storage outside the cluster dependency
  path.
- **Easier:** Backup growth is bounded by ZFS quota rather than convention.
- **Harder:** `xyz` becomes the first backup target dependency, so loss of `xyz`
  still requires a later off-site or second-host copy.
- **Trade-off:** RustFS is not in nixpkgs, so it is consumed through the
  upstream RustFS flake and pinned by `flake.lock`.
