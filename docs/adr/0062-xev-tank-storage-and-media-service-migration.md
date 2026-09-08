# ADR-0062: Move bulk storage ownership and media services to xev

**Status:** Accepted, amended by ADR-0064; preparation in progress
**Date:** 2026-08-23
**Amended:** 2026-09-08
**Applies to:** `hosts/xev`, `hosts/xyz`, XFS, mergerfs, NFS, Plex, qBittorrent, Stash
**Amended by:** ADR-0064

## Context

ADR-0063 has completed the storage split on `xyz`: `/tank` is a mergerfs
namespace over two independent XFS branches. The retired ZFS media and
downloads copies have been destroyed after observation. The encrypted
`secure` pool remains on `xyz`, including the restored games dataset at
`/games`, vault, keystore, and Kubernetes backup replica.

`xev` is the always-on server and already runs Kubernetes, backup, build, and
browser workloads. Its direct link to `xyz` negotiates at 2.5 GbE. Moving bulk
storage and its services together avoids sending scans and torrent rechecks
over that link and removes their dependence on workstation availability.

The original version also proposed moving encrypted storage and qualifying
an unattended unlock design. ADR-0064 superseded that part of the plan.
This amendment presents only the remaining bulk migration; the historical
proposal is retained in Git history.

## Decision

Move the complete two-branch XFS ownership unit and mergerfs `/tank` to `xev`.
Preserve `/tank/media`, `/tank/downloads`, and `/tank/stash`, including file
metadata, shared-group permissions, branch placement, and the reviewed
mergerfs policy. Do not reformat or relabel disks as an incidental step.

Keep `secure`, `/games`, `/vault`, Calibre, Calibre-Web, and the independent
Kubernetes backup replica on `xyz`. No secure-pool import or unlock changes
are prerequisites for this move. Previously discussed TPM and firmware work
is not a bulk-migration gate unless a concrete hardware compatibility issue
requires firmware maintenance separately.

Prepare packages and filesystem support first, with no bulk mounts, exports,
or media services activated on `xev`. Define and review the source retirement
and destination activation configurations together before the physical move.
Both XFS branch mounts must be required before mergerfs starts. Consumers
must check the real storage mount and remain stopped if it is unavailable.

Move qBittorrent, Stash, and Plex to host-native services on `xev`, one at a
time, with independent application-state backups and rollback points. During
any interval when the disks are on `xev` and services remain on `xyz`, provide
explicit NFS client mounts and fail-closed consumer dependencies before
resuming those services. Account for NFS clients changing export ownership,
service endpoints, user/group IDs, and application-state storage on `xev`.

Qualify Plex hardware transcoding alongside existing Kubernetes GPU workloads.
If coexistence is unacceptable, track Kubernetes placement as a separate
decision after establishing the storage and application-state migration.

## Remaining stages and gates

1. **Prepare xev (#233).** Build the current system with XFS and mergerfs tools.
   Prepare inactive destination mounts and health monitoring. Qualify physical
   attachment capacity, disk health, and storage/controller suitability.
   Activate and verify the preparation through the Kubernetes maintenance
   workflow; a successful build alone does not qualify the running host.
2. **Move bulk ownership (#236).** Record branch inventories and application
   state backups. Stop all writers and exports, unmount both branches cleanly,
   and move the complete pair. Ensure only one host can mount them. Validate
   destination mounts, metadata, NFS, and the intermediate client configuration
   before resuming consumers. Retain a bounded physical return plan to `xyz`.
3. **Move qBittorrent and Stash (#237).** Back up and transfer each application's
   state independently, preserve content paths, and verify seeding, download
   behavior, catalog access, permissions, and clients.
4. **Move Plex (#238).** Preserve its database and metadata, validate playback
   and transcoding, and qualify GPU coexistence.
5. **Qualify and retire old ownership (#239).** Test reboot recovery, missing
   branch/mount behavior, application-state restore, and client reconnection.
   After observation, remove superseded xyz bulk/service configuration and
   explicitly authorized application-state rollback copies.

Physical operations, service cutovers, and reboots remain separately scheduled
maintenance actions. Hardware identities, commands, recovery procedures, and
operational evidence belong in the private runbook.

The ownership move is prepared as paired opt-in boot targets,
`xyz-tank-on-xev` and `xev-tank-owner`. Ordinary host targets retain current
ownership until the physical cutover is accepted. A private coordinator run
from xyz builds and stages both targets without switching the running systems,
preserves rollback closures, and separates shutdown from post-move verification.
The operator moves the disks while both hosts are off. Kubernetes maintenance
on xev follows ADR-0068; xyz is not a Kubernetes node. Media services remain on
xyz behind mount and explicit resume guards during this intermediate phase.
After acceptance, reconcile the ordinary host targets before routine rebuilds;
the opt-in targets are not a permanent parallel configuration.

## Alternatives considered

### Keep bulk storage and media services on xyz

Retains workstation maintenance as a shared-storage outage; not selected.

### Move the disks but keep services permanently on xyz

Useful as a short transition, but adds network dependence and limits heavy
storage operations to the link. Not the target state.

### Copy to replacement disks already attached to xev

Offers an easier physical rollback, but requires an additional complete set
of disks. Revisit if a capacity refresh is approved before migration.

### Move secure storage or put Plex in Kubernetes at the same time

Deferred under ADR-0064. Each introduces independent recovery, ownership, or
scheduling decisions that are not required for the bulk move.

## Consequences

- `xev` becomes the sole bulk-storage and media-service owner.
- The XFS pair remains non-redundant replaceable storage; mergerfs is no backup.
- `xyz` remains the secure-storage owner and independent backup failure domain.
- Stable content paths reduce application migration work, but endpoints and
  host dependencies still require explicit updates.
- xev capacity and recovery qualification must include its existing workloads.

## Tracking

Forgejo milestone: **XEV tank storage and media migration**.
Remaining issues: **#233, #236, #237, #238, #239**.
The secure rename (#259) and ADR-0063 observation/retired-dataset cleanup are
complete. The former secure-move prerequisites (#234 and #235) are superseded
for this migration by ADR-0064.
