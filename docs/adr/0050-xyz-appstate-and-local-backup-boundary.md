# ADR-0050: xyz appstate and local backup boundary

**Status:** Accepted, amended by ADR-0059

**Date:** 2026-05-18

**Applies to:** `xyz`, durable application state, local host backups

## Context

The host runs services whose small databases and configuration are durable, as
well as container, desktop, and package state that can be rebuilt. Backing up a
broad system directory treats these different recovery classes alike and either
copies too much transient data or risks omitting important application state.

## Decision

Give selected durable service state its own ZFS appstate boundary while
retaining the paths expected by each service. Keep rebuildable runtime data and
replaceable bulk content outside that boundary unless a later decision promotes
them.

Replicate the appstate subtree with ZFS to encrypted local backup storage on a
schedule. Apply the same local replication boundary to the host-level
Kubernetes backup target. This copy provides fast host-local recovery and does
not replace off-host protection. Home-directory protection follows the
file-selective model in
[ADR-0059](0059-file-selective-home-backup-and-storage-monitoring.md).

Public configuration owns the typed storage and service interfaces. Concrete
datasets, service selections, schedules, encryption policy, and recovery
procedures belong in the private infrastructure repository under
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Acceptance contract

- Selected durable service state must remain within the ZFS appstate boundary.
- Backup jobs must fail closed when their encrypted destination is unavailable.
- Service behavior and restore assumptions must be validated before obsolete
  pre-migration copies are removed.
- Rebuildable runtime and replaceable bulk data must remain excluded unless
  their recovery classification changes through review.

## Consequences

- ZFS replication covers durable application state without copying a broad
  runtime tree.
- Services retain their normal paths rather than adopting a backup-specific
  layout.
- Local backup storage remains in the same host failure domain.
- Private configuration is the source of truth for the concrete inventory and
  recovery procedure.

## Alternatives considered

### Back up the complete system state tree

Rejected because it mixes durable service state with large rebuildable runtime
data and makes recovery scope unclear.

### Exclude all service state from host backups

Rejected because small application databases and configuration may not be
reconstructible from declarative configuration alone.
