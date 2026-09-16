# ADR-0058: Dedicated xyz runtime storage

**Status:** Accepted, amended by ADR-0061 and on 2026-09-10

**Date:** 2026-07-30

**Applies to:** `xyz`, container runtime and game-session state, backups

## Context

Rebuildable container and game-session state was competing with workstation
root and home capacity. These paths have different recovery and growth behavior
from durable application state and game installations.

At adoption time the workstation was also an opportunistic Kubernetes worker.
Moving runtime data could not make it a durable cluster-storage node or make
ordinary workstation maintenance depend on replica reconstruction.

## Decision

Use a dedicated, natively encrypted, single-device ZFS pool for node-local
runtime data. Separate major runtime classes into datasets and apply independent
quotas so growth in one class cannot exhaust the others. Retain service-native
paths and keep game installations on their separate bulk-storage boundary.

Classify container, build-daemon, and game-session state as rebuildable. Do not
include it in routine application-state backups. Temporary migration protection
may be retained only through a bounded validation window.

Keep durable cluster-replica scheduling disabled on the workstation. ADR-0061
later retired its Kubernetes worker role; the retired agent state is no longer
active and remains outside routine backups pending ordinary storage
housekeeping.

Concrete devices, datasets, quotas, encryption policy, and migration or
recovery procedures belong in the private infrastructure repository under
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Acceptance contract

- Quotas must prevent one runtime class from consuming all shared device
  capacity.
- Migration must preserve source snapshots and a bounded rollback point until
  the new mounts, services, backup replication, and a restore check pass.
- The storage must not become a durable cluster-replica location.

## Consequences

- Rebuildable runtime growth no longer consumes workstation root capacity.
- Workloads keep their established paths.
- Failure of the single runtime device can discard its contents; services are
  recreated from declarative configuration.
- Routine workstation maintenance does not trigger cluster replica rebuilds.
- Any host-local migration or backup copy remains in the same host failure
  domain and does not satisfy off-host recovery.

## Alternatives considered

### Put runtime data on bulk game storage

Rejected because game installations and mutable runtime state have different
capacity and recovery policies.

### Add the device as durable cluster storage

Rejected because an interactive workstation is not an appropriate steady-state
replica failure domain.

### Use one unbounded filesystem

Rejected because one runtime cache could consume the capacity needed by other
services.

### Back up all runtime directories

Rejected because rebuildable images, containers, caches, and agent state add
large, potentially inconsistent copies without improving durable-state
recovery.
