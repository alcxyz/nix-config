# ADR-0052: xev primary Kubernetes backup target with xyz ZFS replica

**Status:** Accepted, staged
**Date:** 2026-07-18
**Applies to:** `hosts/xev`, `hosts/xyz`, host-level S3 backups, Longhorn and database backup clients
**Supersedes:** ADR-0039

## Context

ADR-0039 placed the host-level Kubernetes backup target on `xyz` to keep it
outside the k3s and Longhorn dependency path. That removed the circular
dependency on in-cluster object storage, but made routine backup writes depend
on the workstation and its encrypted `tank` pool.

`xev` now has a dedicated 1 TB hard disk that is neither its system disk nor a
Longhorn disk. A host-level RustFS process on `xev` therefore remains outside
the Kubernetes scheduling and Longhorn storage paths even though the machine is
also a k3s server. `xyz` can retain an independently served ZFS copy with
snapshots, so moving the first-write target does not make `xev` the sole
recovery location.

## Decision

Use the following one-way topology:

| Role | Host | Endpoint | Storage |
| --- | --- | --- | --- |
| Authoritative backup target | `xev` | `192.168.1.13:9200` | dedicated 1 TB ext4 disk at `/var/lib/k8s-backup-replica` |
| Pull replica and recovery endpoint | `xyz` | `192.168.1.10:9100` | `tank/k8s-backups`, with ZFS snapshots and the existing local ZFS replication chain |

Longhorn, etcd export automation, CloudNativePG, and logical database dump jobs
write only to `xev`. `xyz` pulls a verified S3 mirror from `xev` daily. The
existing `xyz` ZFS backup job then snapshots and replicates that local replica;
it runs after the S3 mirror window.

The two RustFS endpoints use the same bucket credentials during migration so
the existing object tree can be copied and validated without rewriting object
metadata. The sync implementation must load credentials from systemd credential
files without placing secret values in process arguments.

This is deliberately not an active-active or two-way object-store design.
Backup writers have one endpoint, replication has one direction, and a role
reversal is an explicit recovery procedure.

## Cutover Gate

Do not redirect any writer until all of these pass:

1. The dedicated `xev` filesystem is mounted from its expected label and is not
   the root filesystem or a Longhorn disk.
2. The initial `xyz` to `xev` mirror completes and per-bucket object and byte
   counts agree after a final delta pass.
3. A bounded object read and at least one application-appropriate restore test
   succeed against the `xev` endpoint.
4. The `xev` service is declarative, survives a separately approved reboot, and
   fails closed if the dedicated disk is absent.
5. Every backup-client manifest is prepared for the new endpoint and can be
   switched as one reviewed GitOps change.

After writers move, verify fresh Longhorn and database backup artifacts on
`xev` before enabling `xev` to `xyz` mirroring. Retain the pre-cutover `xyz`
objects and ZFS snapshots throughout the acceptance window.

## Consequences

- Routine backup writes no longer require `xyz` or its pools to be online.
- Loss of `xev` pauses new backups but does not remove the latest verified `xyz`
  recovery copy.
- `xyz` retains efficient ZFS snapshots and its local replication chain without
  remaining the operational first-write dependency.
- The primary disk is ext4 and has no local snapshot facility; recovery depth
  comes from the `xyz` ZFS replica rather than from snapshots on `xev`.
- Backup availability is intentionally single-writer. This is simpler and less
  failure-prone than attempting synchronous or bidirectional RustFS replication.
