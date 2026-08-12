# ADR-0050: xyz appstate and local backup boundary

**Status:** Accepted, amended by ADR-0059

**Date:** 2026-05-18

**Applies to:** `xyz`, ZFS app state, local host backups, media services

## Context

`xyz` runs a mix of NixOS-native services, Docker-adjacent workloads, media
tools, game tooling, and rebuildable desktop/runtime state. Before this
decision, important service state lived directly under broad `/var/lib`
directories, while some older services also left root-level compatibility
mountpoints and stale application state behind.

That made host backups too coarse. A full `/var` backup includes a large amount
of rebuildable runtime state, while omitting `/var/lib` entirely risks losing
small but important application databases and config.

## Decision

Treat selected service state as a dedicated ZFS appstate boundary on `xpool`.
The appstate datasets are mounted at the service-native paths under `/var/lib`
so applications do not need private path conventions.

The selected appstate set currently includes:

- Calibre library state
- Calibre-Web state
- Plex application state
- qBittorrent state
- Stash application state

Replicate the appstate subtree to a local encrypted backup pool with a systemd
timer. Also replicate the host-level Kubernetes backup object-store dataset into
the same local backup pool. The initial full-dataset home replica is replaced by
the file-selective design in [ADR-0059](0059-file-selective-home-backup-and-storage-monitoring.md).
The backup target is host-local and intended as a fast local recovery copy, not
as a replacement for off-host backups.

The backup pool and the main data pool should both keep a manual passphrase
fallback while also supporting the private age/YubiKey auto-unlock mechanism.
The public repository records only the dataset and service wiring. Key
envelopes, unlock material, and recovery procedure details belong in the
private `nix-secrets` flake.

## Consequences

- Backups can target the appstate subtree instead of all of `/var`.
- The Kubernetes backup target has a local ZFS replication copy outside `tank`.
- `/home` uses the narrower, file-selective backup boundary defined by ADR-0059.
- Services retain normal `/var/lib/...` paths, avoiding bespoke application
  config paths for common state.
- Rebuildable runtime state such as Flatpak caches, Docker runtime state,
  Kubernetes runtime directories, and package/build caches remain outside the
  appstate backup boundary unless explicitly promoted later.
- Local backup jobs fail closed if the backup pool is not imported, unlocked, or
  encrypted.
- Key and recovery procedures are intentionally documented privately.

## Follow-Ups

- Remove old pre-migration `/var/lib` copies only after service behavior and
  backup restore assumptions have been validated.
- Keep media libraries and game installs out of the appstate backup by default;
  treat them as bulk data with separate retention and recovery decisions.
