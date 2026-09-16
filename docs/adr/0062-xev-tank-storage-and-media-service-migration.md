# ADR-0062: Move bulk storage ownership and media services to xev

**Status:** Accepted, amended by ADR-0064; preparation in progress
**Date:** 2026-08-23
**Amended:** 2026-09-07
**Applies to:** `xev`, `xyz`, replaceable bulk storage and dependent media services
**Amended by:** ADR-0064

## Context

ADR-0063 separated replaceable bulk data from encrypted, recovery-oriented
storage. The replaceable bulk data and its high-I/O services still depend on an
interactive workstation. Moving ownership and dependent services to an
always-on server reduces that availability coupling and avoids sustained remote
I/O between the services and their data.

The original decision also proposed moving secure storage. ADR-0064 superseded
that part and keeps secure storage in a separate ownership and failure domain.

Concrete device inventory, storage identifiers, exports, endpoints, service
state locations, and operational procedures are private under
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Decision

Move the complete two-branch XFS ownership unit and its mergerfs view to `xev`
without changing its data classification or treating the move as a reformat.
Preserve stable application-visible content paths, branch placement, the
reviewed mergerfs policy, and filesystem metadata needed by consumers.

Keep secure, recovery-oriented storage and its independent backup role on
`xyz`, as required by [ADR-0064](0064-keep-secure-storage-on-xyz.md). A secure
storage move or unlock-policy change is outside this migration.

Prepare filesystem support, fail-closed mounts, and monitoring before activation.
Review source retirement and destination activation together. Only one host may
own the storage at a time, and consumers must remain stopped when the intended
storage is unavailable.

Move dependent media services separately after storage ownership, with an
independent application-state backup, validation, and rollback point for each
stage. Any temporary remote-service stage must require the intended remote
storage through explicit NFS mounts and must not fall back to an empty local
directory.

Hardware-accelerated media behavior must be qualified alongside existing GPU
workloads. If coexistence is unacceptable, a separate placement decision is
required.

## Remaining stages and gates

1. **Prepare the destination
   ([#233](https://git.alc.xyz/alcxyz/nix-config/issues/233)).** Qualify storage
   attachment, health, controller suitability, inactive mounts, and monitoring
   on the running host. A successful build alone is insufficient.
2. **Move bulk ownership
   ([#236](https://git.alc.xyz/alcxyz/nix-config/issues/236)).** Quiesce all
   writers, transfer the complete ownership unit, prove single-host ownership,
   and validate storage and any temporary client path before resuming consumers.
3. **Move the first dependent services
   ([#237](https://git.alc.xyz/alcxyz/nix-config/issues/237)).** Transfer and
   validate each service state independently while preserving content paths and
   permissions.
4. **Move the hardware-accelerated service
   ([#238](https://git.alc.xyz/alcxyz/nix-config/issues/238)).** Validate service
   state, playback, acceleration, and coexistence with other GPU workloads.
5. **Qualify and retire old ownership
   ([#239](https://git.alc.xyz/alcxyz/nix-config/issues/239)).** Test restart,
   missing-storage, restore, and client-reconnection behavior before removing
   superseded configuration or rollback copies.

These hardware and runtime gates remain pending. This ADR does not authorize or
record their completion, and configuration preparation does not activate the
move.

## Alternatives considered

### Keep bulk storage and its services on xyz

Rejected because workstation maintenance would remain a shared-storage outage.

### Move storage while keeping services permanently remote

Rejected as the target state because it retains network dependence for heavy
storage work.

### Copy onto replacement hardware

Deferred. It offers a simpler physical rollback but requires a separate capacity
purchase and refresh decision.

### Move secure storage or change service orchestration at the same time

Rejected for this migration. Each adds independent availability, recovery, or
scheduling decisions.

## Consequences

- `xev` becomes the owner of replaceable bulk storage and its dependent media
  services after the pending gates pass.
- The XFS/mergerfs bulk layer remains non-redundant and is not a backup.
- `xyz` remains the secure-storage owner and an independent backup failure
  domain.
- Stable consumer paths reduce application migration work, while endpoints and
  host dependencies still require deliberate updates.
- Destination capacity, hardware, and recovery behavior must be qualified with
  its existing workloads before activation.
