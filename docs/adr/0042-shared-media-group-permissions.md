# ADR-0042: Shared media group permissions for torrent and Stash storage

**Status:** Accepted
**Date:** 2026-05-07
**Applies to:** `modules/nixos/services/torrent`, `modules/nixos/services/stash`, `hosts/xyz`, `gitops/k8s/apps/qbittorrent`

## Context

qBittorrent needs to seed files that live in the same media trees Stash scans and
manages. The previous implementation exposed `/zpool/stash`, `/ypool/stash`, and
`/zpool/media` to qBittorrent through `bindfs` mountpoints under
`/zpool/downloads/*_rtorrent`. Those FUSE mounts forced ownership to
`rtorrent:rtorrent`, while Stash continued to use the real paths with
`stash:stash` ownership.

That worked, but it made the storage contract depend on extra mount views:

- qBittorrent and Stash used different paths for the same files.
- qBittorrent's k8s pod depended on host submounts under a hostPath PV.
- The bindfs units were ordered around Docker even after qBittorrent moved to
  k8s.
- Remount recovery depended on Kubernetes mount propagation behavior.

The real requirement is not UID remapping. The requirement is that qBittorrent,
Stash, Plex, and the operator can read and write selected media trees without
breaking each other's files.

## Decision

Use a shared host group, `media`, as the permission boundary for media datasets.

The host should manage `/zpool/stash`, `/ypool/stash`, and `/zpool/media` as
group-writable shared media roots:

- top-level directories use mode `2775`
- the group is `media`
- default ACLs grant `media` read/write/search access for newly created content
- a one-time migration applies the `media` ACL recursively to existing content
- qBittorrent mounts the real media paths directly in k8s
- Stash keeps using the real media paths directly in Docker
- containers receive supplemental membership in the numeric `media` group

Keep compatibility for existing qBittorrent save paths by replacing the old
`/zpool/downloads/stash_rtorrent`, `/zpool/downloads/stash2_rtorrent`, and
`/zpool/downloads/media_rtorrent` mountpoints with symlinks to the real media
roots once the old bindfs mounts are gone.

## Alternatives Considered

**Keep bindfs and harden ordering** - acceptable as a short-term fix, but it
keeps the wrong abstraction. The same files continue to have different apparent
owners and paths depending on which workload sees them.

**Move or import files between app-owned trees** - rejected because it adds copy
or rename workflows and makes seeding correctness depend on automation outside
qBittorrent.

**Make every workload run as the same UID/GID** - simple, but it collapses
service identity. Separate service users remain useful for process ownership,
state directories, and auditability.

## Consequences

- FUSE bindfs is no longer required for torrent/Stash interoperability.
- qBittorrent paths become more explicit in Kubernetes manifests.
- The shared media group becomes the durable contract for media write access.
- Existing files need a one-time ACL migration before removing the bindfs views.
- Containers must keep supplemental `media` group membership in addition to
  their service-specific primary UID/GID.
