# ADR-0063: Split replaceable bulk data from secure storage

**Status:** Accepted, staged
**Date:** 2026-08-29
**Applies to:** `hosts/xyz`, `tank`, mergerfs, ZFS, Plex, qBittorrent, Stash, NFS

## Context

The `/tank` namespace historically described one encrypted ZFS pool. After the
Stash capacity migration, `/tank/stash` instead became a mergerfs view over two
independent XFS filesystems. The remaining ZFS pool is a two-disk mirror, while
the XFS branches prioritize usable capacity and independent file recovery over
whole-tree redundancy.

`tank/media` contains replaceable Plex and qBittorrent content. `tank/downloads`
and `tank/games` no longer contain material data. Keeping those paths on the
encrypted mirror spends redundant capacity on content that can be acquired
again, while the much larger Stash tree already follows the bulk-storage
policy.

qBittorrent records absolute save paths below both `/tank/media` and
`/tank/stash`, and Plex serves `/tank/media/plex`. Changing those paths would
add application-state migration and unnecessary rechecks to a storage-layout
change.

## Decision

Make `/tank` the stable namespace for replaceable bulk data and mount the
two-branch mergerfs filesystem at its root. Its initial directories are:

- `/tank/stash`
- `/tank/media`
- `/tank/downloads`

Copy the existing ZFS media and download trees into the mergerfs hierarchy
while preserving their absolute paths, ownership, ACLs, extended attributes,
timestamps, sparse files, and any intra-tree hard links. Remove the empty games
path and its export rather than recreating it on bulk storage.

The mergerfs layer remains intentionally non-redundant and does not become a
backup. Loss of one branch loses the files placed on that branch while leaving
the other branch independently readable. Only data classified as replaceable
may live there.

Retain valuable and recovery-oriented data on the mirrored native-encrypted
ZFS pool. After the bulk cutover is proven, rename that pool to `secure` and
move its public mount hierarchy below `/secure` in a separate maintenance
stage. Preserve `/vault` as the user-facing convenience path, retargeted to the
secure hierarchy. The pool rename must not be combined with the bulk-data
copy, service cutover, or physical move to `xev`.

Keep qBittorrent, Stash, Plex, and NFS on their existing host during this
layout change. Every service must require its real mount and must fail rather
than write into an unmounted placeholder directory. The later host migration
from [ADR-0062](0062-xev-tank-storage-and-media-service-migration.md), as
amended by [ADR-0064](0064-keep-secure-storage-on-xyz.md), moves only the bulk
XFS pair. The secure ZFS mirror remains owned by `xyz`.

## Cutover gates

1. Classify every source subtree as replaceable before copying it to bulk
   storage.
2. Record qBittorrent path coverage and stop all writers for the final delta.
3. Verify the copy at content and metadata levels before changing mounts.
4. Preserve the exact `/tank/media`, `/tank/downloads`, and `/tank/stash`
   paths across the cutover.
5. Keep the former ZFS datasets unmounted, read-only, and available for a
   bounded rollback window.
6. Recheck qBittorrent content and validate Plex, Stash, NFS, and ordinary file
   access before destroying the former datasets.
7. Authorize dataset destruction and the later pool rename separately.

Detailed device identities, state evidence, copy commands, confirmation
tokens, and rollback operations belong in the private migration runbook.

## Alternatives considered

### Keep media on the encrypted mirror

Rejected because the data is replaceable, consumes a meaningful share of the
redundant pool, and would force Plex and qBittorrent to span two storage
policies indefinitely.

### Change application paths to a new bulk mount

Rejected because preserving `/tank` avoids a qBittorrent retarget, Plex library
rewrite, and changes to existing clients.

### Mount mergerfs only at `/tank/stash`

Rejected as the target state because it makes the historical pool name describe
two unrelated protection classes and leaves replaceable media on secure
storage.

### Rename the ZFS pool during the bulk cutover

Rejected because it combines data movement, mount replacement, unlock-policy
changes, backup changes, and rollback changes into one fault domain.

## Consequences

- `/tank` consistently means replaceable, capacity-oriented bulk data.
- The secure mirror becomes smaller and semantically focused.
- qBittorrent and Plex retain their current absolute content paths.
- Bulk-data loss remains possible after a single XFS branch failure and must be
  accepted for every directory placed there.
- The secure-pool rename on `xyz` and the bulk physical move to `xev` remain
  separately reversible work.
