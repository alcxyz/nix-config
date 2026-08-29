# ADR-0062: Move bulk and secure storage ownership and media services to xev

**Status:** Accepted, staged
**Date:** 2026-08-23
**Applies to:** `hosts/xev`, `hosts/xyz`, bulk storage, secure storage, NFS, Plex, qBittorrent, Stash, Kubernetes backup recovery

## Context

The storage currently owned by the interactive workstation `xyz` is being
split by [ADR-0063](0063-split-replaceable-bulk-and-secure-storage.md) into a
two-branch XFS/mergerfs bulk namespace at `/tank` and a smaller encrypted ZFS
mirror for valuable and recovery-oriented data. Together they hold data used
by Plex, qBittorrent, and Stash, plus a ZFS pull replica of the Kubernetes
backup object store. This makes those storage duties unavailable during normal
workstation maintenance.

`xev` is the always-on server and already owns stable Kubernetes, backup, build,
and browser-streaming duties. The direct network path between `xyz` and `xev`
now negotiates at 2.5 GbE. That is sufficient for media streaming and ordinary
shared-file access, although it can limit peak sequential throughput from the
two mirrored data vdevs.

The storage-bound services should therefore eventually run beside their disks
instead of sending their scanning, recheck, and library traffic over NFS.

## Decision

Complete ADR-0063 first. Then move physical ownership of the bulk XFS pair and
import authority for the secure ZFS mirror from `xyz` to `xev` in separately
approved stages. Preserve the bulk application paths while moving the secure
mount hierarchy as documented by ADR-0063.

Keep the `xev` root filesystem unencrypted. Preserve native encryption on the
secure pool, but do not place any persistent plaintext credential capable of
unlocking it on the unencrypted root filesystem. Give `xev` an independent
unwrap credential sealed to its TPM and an approved boot state. Release that
credential only into volatile runtime storage for the unlock service. A normal
approved boot must unlock the secure pool without operator input; an unlock
failure must not prevent `xev` itself from booting and must leave every secure
pool consumer
stopped.

Retain an operator-assisted recovery identity outside `xev`. During the
rollback window, keep `xyz` authorized independently rather than copying its
root-resident identity to `xev`. Exact enrollment material, recovery factors,
boot-policy measurements, and provisioning commands belong in private
configuration and the private migration runbook.

This protects the pool from detached-drive access without claiming that an
unencrypted, mutable root has the same physical-tamper properties as an
encrypted or integrity-verified root. That narrower boundary is accepted for
this always-on server.

The stages are:

1. Prepare `xev` with the same reviewed OpenZFS userspace and kernel-module
   pairing used by `xyz`, plus a stable ZFS host ID. Do not configure the secure
   pool as an extra pool, enable its unlock policy, or attempt an import in this
   stage.
2. Prepare the private unlock policy, storage monitoring, NFS ownership,
   consumer mount ordering, and backup-replica replacement. These changes must
   remain inactive until the physical cutover gate is approved.
3. Stop all storage consumers, move each complete storage ownership unit as
   documented privately, import or mount it only on `xev`, and validate
   topology, health, encryption where applicable, mounts, permissions,
   monitoring, and NFS.
4. Move qBittorrent, Stash, and Plex to host-native services on `xev` after the
   pool is stable there. Migrate their application state separately from their
   bulk media trees and retain a verified rollback copy.
5. If native Plex contends unpredictably with Kubernetes GPU workloads, move
   Plex into Kubernetes as a singleton with explicit GPU admission. Keep its
   durable application state on replicated storage and its transcode directory
   ephemeral. Kubernetes placement provides compute mobility, not media
   availability when `xev` itself is down.

Keep Calibre and Calibre-Web on `xyz` unless a later decision moves their
independent library and application-state boundary.

Moving the secure-pool Kubernetes backup dataset onto `xev` removes its status as an independent
off-host replica of the authoritative `xev` backup disk. Before physical
cutover, establish and capacity-check an independently replicated ZFS recovery
copy on `xyz` or another host. A same-host copy on the secure pool may remain useful but
must not be counted as satisfying that failure-domain requirement. Amend
[ADR-0052](0052-xev-primary-k8s-backup-target.md) when the replacement topology
is selected.

Detailed device identities, attachment layout, unlock material, maintenance
commands, and rollback procedure remain in the private runbook boundary from
[ADR-0048](0048-xyz-small-nvme-retirement.md).

## Cutover gates

No pool export, import, power action, service relocation, or backup endpoint
change is authorized by this ADR alone. Before physical cutover:

1. Complete ADR-0063, then close the existing private storage-health gates for
   both the secure mirror and independent bulk branches.
2. Confirm adequate bays, storage-controller ports, power, cooling, and stable
   device discovery on `xev` without recording hardware fingerprints publicly.
3. Build the complete `xev` closure with the selected OpenZFS module and qualify
   its activation and reboot through the established Kubernetes-node
   maintenance workflow.
4. Prove the unlock design first with disposable encrypted test data. Verify an
   unattended approved reboot, absence of persistent plaintext unlock material,
   fail-closed behavior when the TPM policy is unavailable, operator-assisted
   recovery, and a normal `xev` boot while the test pool remains locked.
5. Prove bidirectional network and NFS behavior, including failure when the
   export is absent. Services must never write into an unmounted local `/tank`
   directory.
6. Establish a current independent backup and a tested restore path, including
   the replacement for the current `xyz` Kubernetes backup replica.
7. Prepare bounded rollbacks that return each complete storage unit to `xyz`
   without permitting simultaneous import or mount ownership by both hosts.

## Alternatives considered

### Keep all storage and media services on xyz

Rejected as the target state because routine workstation maintenance continues
to remove otherwise server-like storage and media duties.

### Move the storage but leave all media services on xyz

Acceptable only as a short migration stage. It removes the disks from the
workstation but sends heavy scans, torrent rechecks, and bulk reads and writes
through a link that can be slower than the pool's sequential throughput.

### Build replacement storage on xev and replicate before cutover

Operationally safer because the existing pool remains an immediate rollback,
but it requires another complete set of disks. Prefer this route if a capacity
refresh is approved before the physical move.

### Put Plex in Kubernetes immediately

Deferred. Combining the pool move, application-state migration, ingress change,
and GPU scheduling change would make rollback and fault isolation harder. A
host-native move establishes the storage boundary first.

### Encrypt the xev root filesystem

Not selected. TPM-assisted root encryption could still permit unattended
restarts and would protect additional host runtime state from detached-disk
access, but it adds little to the selected pool-focused threat boundary. The
root must therefore remain free of plaintext material that can unlock the secure pool.

### Store the secure-pool unlock identity directly on the xev root filesystem

Rejected. It would make possession of the unencrypted root disk sufficient to
decrypt the pool and would collapse the intended encryption boundary.

## Consequences

- `xev` becomes the authoritative bulk-storage and media-service host.
- Normal `xyz` maintenance no longer removes the storage after the service moves
  complete.
- Network clients are limited by 2.5 GbE, while pool-local services retain full
  local throughput.
- `xev` gains a larger storage and availability blast radius, making its
  maintenance gates and independent backups more important.
- The current `xev`-primary, `xyz`-replica Kubernetes backup topology must be
  amended before physical cutover.
- `xev` can restart unattended without encrypting its root filesystem; failure
  to unlock the secure pool affects only its consumers.
- TPM enrollment and assisted recovery add a private provisioning and testing
  obligation before the real secure pool is authorized on `xev`.
- The first preparatory configuration changes no pool ownership and performs no
  import, unlock, service, or NFS action.

## Tracking

- Forgejo milestone: **XEV tank storage and media migration**
- Issue #233: prepare `xev` for ZFS ownership without importing the pool
- Issue #234: qualify unattended TPM-bound unlock on unencrypted `xev` root
- Issue #235: re-establish an independent Kubernetes backup replica
- Issue #236: move physical pool ownership with bounded rollback
- Issue #237: move qBittorrent and Stash beside the pool
- Issue #238: move Plex and qualify Kubernetes GPU coexistence
- Issue #239: qualify recovery and retire `xyz` pool ownership

The public issues contain architectural gates and redacted acceptance criteria.
Host-specific enrollment, hardware, execution, and recovery details remain in
private configuration and the private runbook.
