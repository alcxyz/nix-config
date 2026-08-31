# ADR-0064: Keep secure storage on xyz while moving bulk storage to xev

**Status:** Accepted, staged
**Date:** 2026-08-31
**Applies to:** `hosts/xyz`, `hosts/xev`, secure ZFS storage, bulk storage, media services, Kubernetes backup recovery
**Amends:** ADR-0052, ADR-0062, ADR-0063

## Context

ADR-0062 originally coupled the eventual move of the two-branch XFS bulk
filesystem with moving the encrypted ZFS mirror to `xev`. ADR-0063 has since
separated those storage policies: `/tank` is replaceable bulk data, while the
remaining mirrored ZFS data is valuable or recovery-oriented.

The media services need the bulk filesystem but do not need the secure mirror.
Moving the secure mirror would introduce a new TPM-bound unattended-unlock
design on `xev`, expand the physical cutover, and move the Kubernetes backup
replica onto the same host as its authoritative source. None of those changes
is required to make bulk storage and media services independent of `xyz`.

## Decision

Keep the encrypted ZFS mirror owned, imported, unlocked, monitored, and served
by `xyz`. Rename the pool from its historical `tank` name to `secure` and move
its live hierarchy from `/tank` to `/secure` as the remaining stage of
ADR-0063. Preserve `/vault` as a convenience link to `/secure/vault`.

Move only the two independent XFS bulk branches and their mergerfs `/tank`
namespace to `xev`. Move qBittorrent, Stash, and Plex beside that bulk storage
in separate application-state stages. During any intermediate remote-service
stage, consumers must require the real NFS mount and fail rather than write to
a local placeholder.

The `xyz` dataset `secure/k8s-backups` remains the independent pull replica and
recovery endpoint for the authoritative Kubernetes backup target on `xev`.
The secure mirror must not be counted as part of the `xev` storage ownership
unit or as a prerequisite for the bulk move.

Do not provision a production secure-pool TPM credential on `xev` in this
migration. A future proposal may move `secure`, but it must independently
revisit unattended unlock, recovery authorization, failure-domain separation,
import ownership, and rollback. That future decision must not be inferred from
the bulk-storage migration.

## Stages

1. Complete the guarded `tank` to `secure` rename on `xyz`, including unlock,
   mount, NFS, monitoring, backup, and rollback validation.
2. Observe the clean `/tank` and `/secure` split while retaining the retired
   read-only bulk datasets for the ADR-0063 rollback window.
3. Prepare `xev` for only the XFS branches, mergerfs mount, NFS ownership, and
   bulk-storage health monitoring.
4. Move the complete XFS bulk ownership unit with a bounded rollback to `xyz`.
5. Move qBittorrent, Stash, and Plex one at a time with independent
   application-state rollback points.

## Consequences

- `/tank` has one meaning: replaceable bulk capacity.
- `/secure` has one meaning: encrypted, mirrored, recovery-oriented storage on
  `xyz`.
- The immediate `xev` migration no longer depends on OpenZFS import ownership,
  TPM enrollment, or secure-pool recovery provisioning.
- The Kubernetes backup replica remains in a separate host failure domain from
  its authoritative `xev` target.
- Secure storage remains unavailable during `xyz` maintenance; this is an
  accepted trade-off for the narrower migration.
- Clients may use `xev` for bulk exports and `xyz` for secure exports.
- A later secure-pool move remains possible but becomes a new, separately
  approved migration.

## Tracking

- Forgejo milestone: **XEV tank storage and media migration**
- Issues #233 and #236 are narrowed to XFS/mergerfs preparation and ownership.
- Issues #237 and #238 retain the qBittorrent, Stash, and Plex moves.
- Issue #239 closes only bulk and media ownership; `xyz` retains `secure`.
- Issues #234 and #235 are no longer prerequisites for this migration.
