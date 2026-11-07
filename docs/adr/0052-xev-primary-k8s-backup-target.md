# ADR-0052: xev primary Kubernetes backup target with xyz ZFS replica

**Status:** Accepted
**Date:** 2026-07-18
**Amended:** 2026-11-07
**History:** [replaced text](archive/0052-xev-primary-k8s-backup-target-history.md)
**Applies to:** host-level S3 backups, replica storage, and backup clients
**Supersedes:** [ADR-0039](archive/0039-xyz-zfs-s3-backup-target.md)

## Context

ADR-0039 moved Kubernetes backups outside the cluster storage dependency path,
but its first-write target was not the best steady-state dependency. A stable
host can own routine writes while an independently managed, snapshot-capable
copy preserves a separate recovery location.

Detailed host storage, endpoints, credentials, schedules, product tuning,
cutover, verification, and recovery procedures are private in accordance with
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Decision

Use one authoritative host-level S3-compatible backup target on `xev`, outside
the Kubernetes scheduling and cluster-storage paths. Replicate it
asynchronously in one direction to independently managed, snapshot-capable ZFS
storage on `xyz`, in another host failure domain. Backup writers were
redirected to the `xev` target on 2026-07-19.

Keep snapshot history directly at the replica destination. A further local
replication of that replica is unnecessary; mirrored storage instead protects
backups of local durable data, as recorded in
[ADR-0050](0050-xyz-appstate-and-local-backup-boundary.md). Retention prunes
only snapshots owned by that mirror job and preserves migrated history.

A mirror host can name a weekly day for its full pass. Without one, every pass
is a full pass. A full pass reconciles every object, including deletions, and
verifies each one by key and size. Every other pass is incremental: it copies
and checks what the source received since the last verified pass, measured
from that pass's start rather than a fixed age so that a failed or missed run
leaves no gap. It does not list the replica or propagate deletions. A pass runs
in full when no verified pass is recorded, when the last full pass is over a
week old, or when the last one attempted failed, so the next run retries it.

A successful pass of either kind creates a snapshot only after all buckets have
verified, recording its scope on the snapshot. An incremental snapshot therefore
proves that the objects received since the last verified pass arrived, and
relies on the last full pass for older ones. A full pass first runs the
incremental copy and logs what its reconcile still had to copy, so incremental
passes that miss objects show up in that count.

Live objects and all retained snapshots share the replica dataset quota.
Capacity planning must allow for migrated history and object churn, with
free-space monitoring. Since pruning follows successful verification, quota
exhaustion requires explicit operator action before replication can resume.

Backup writers use only the authoritative endpoint. Replication has one source
and one destination, and reversing those roles is an explicit recovery action.
The replica remains separate from later bulk-storage ownership changes, as
recorded by [ADR-0064](0064-keep-secure-storage-on-xyz.md).

Pin the object-store implementation to a reviewed release. Concrete versions
and storage-specific tuning belong to the private operational record.

## Acceptance Contract

The writer cutover on 2026-07-19 met the recorded parts of this gate: the
destination is independent of cluster storage, the initial copy was verified,
all client changes went out as one reviewed cutover, and new backup artifacts
were confirmed before steady-state replication began. Three parts have no
recorded result and remain requirements for the authoritative target: a
representative restore from it succeeds, it survives a separately approved
reboot, and it fails safely when its dedicated storage is unavailable. Preserve
the pre-cutover recovery copy throughout the acceptance window.

## Alternatives Considered

**Keep the former first-write target** - rejected because routine backup writes
should depend on the more stable host role.

**Use active-active or bidirectional object storage** - rejected because
single-writer ownership and one-way replication have clearer failure and
recovery behavior.

**Keep only the authoritative copy** - rejected because a second host failure
domain and snapshot history provide independent recovery depth.

**Mirror less often** - rejected because each pass would still take as long,
while the second copy would be older.

## Consequences

Routine writes depend on one stable target, while the replica provides a
separate recovery copy. Loss of the primary pauses new backups but does not
remove the latest verified replica. The design favors explicit recovery over
automatic multi-writer failover.

Incremental passes skip what takes nearly all of a full pass's time: comparing
unchanged objects and listing the replica. In exchange, damage to an older object on the replica, or an older object
missing from it, can go unnoticed until the next full pass, and objects deleted
at the source stay on the replica and in its snapshots until then. Such
snapshots hold a superset of the source's objects.
