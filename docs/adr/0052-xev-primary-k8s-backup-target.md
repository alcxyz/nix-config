# ADR-0052: xev primary Kubernetes backup target with xyz ZFS replica

**Status:** Accepted, amended by [ADR-0064](0064-keep-secure-storage-on-xyz.md)
**Date:** 2026-07-18
**Applies to:** host-level S3 backups, replica storage, and backup clients
**Supersedes:** [ADR-0039](0039-xyz-zfs-s3-backup-target.md)

## Context

ADR-0039 moved Kubernetes backups outside the cluster storage dependency path,
but its first-write target was not the best steady-state dependency. A stable
host can own routine writes while an independently managed, snapshot-capable
copy preserves a separate recovery location.

Detailed host storage, endpoints, credentials, schedules, product tuning,
cutover, verification, and recovery procedures are private in accordance with
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Decision

Use one authoritative host-level S3-compatible backup target outside the
Kubernetes scheduling and cluster-storage paths. Replicate it asynchronously in
one direction to independently managed, snapshot-capable storage in another
host failure domain.

Backup writers use only the authoritative endpoint. Replication has one source
and one destination, and reversing those roles is an explicit recovery action.
The replica remains separate from later bulk-storage ownership changes, as
recorded by ADR-0064.

Pin the object-store implementation to a reviewed release. Concrete versions
and storage-specific tuning belong to the private operational record.

## Acceptance Contract

Do not redirect writers until the destination is independent of cluster storage,
the initial copy is verified, a representative restore succeeds, the service
survives a separately approved reboot, fails safely when its dedicated storage
is unavailable, and all client changes
are ready for one reviewed cutover. Confirm new backup artifacts before enabling
steady-state replication. Preserve the pre-cutover recovery copy throughout
the acceptance window.

## Alternatives Considered

**Keep the former first-write target** — rejected because routine backup writes
should depend on the more stable host role.

**Use active-active or bidirectional object storage** — rejected because
single-writer ownership and one-way replication have clearer failure and
recovery behavior.

**Keep only the authoritative copy** — rejected because a second host failure
domain and snapshot history provide independent recovery depth.

## Consequences

Routine writes depend on one stable target, while the replica provides a
separate recovery copy. Loss of the primary pauses new backups but does not
remove the latest verified replica. The design favors explicit recovery over
automatic multi-writer failover.
