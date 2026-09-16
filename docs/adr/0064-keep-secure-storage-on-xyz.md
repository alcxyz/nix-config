# ADR-0064: Keep secure storage on xyz while moving bulk storage to xev

**Status:** Accepted, staged
**Date:** 2026-08-31
**Amended:** 2026-09-07
**Applies to:** secure storage, replaceable bulk storage, dependent services,
and Kubernetes backup recovery
**Amends:** ADR-0052, ADR-0062, ADR-0063

## Context

[ADR-0062](0062-xev-tank-storage-and-media-service-migration.md) originally
coupled relocation of replaceable bulk storage with relocation of encrypted,
recovery-oriented storage. [ADR-0063](0063-split-replaceable-bulk-and-secure-storage.md)
separated those storage policies. Services that consume bulk data do not
require ownership of the secure storage, and moving both at once would expand
the cutover and weaken the separation between authoritative backups and their
independent replica.

Detailed device inventory, dataset and mount names, encryption and unlock
design, exports, schedules, migration commands, rollback, and recovery
procedures are private in accordance with
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Decision

Keep encrypted, mirrored, recovery-oriented storage owned by `xyz`. Move only
replaceable bulk-storage ownership to `xev`, followed by services whose data
plane depends on that storage. Treat secure storage and bulk storage as separate
ownership and migration units.

Keep the Kubernetes backup replica on `xyz`, in a different host failure domain
from the authoritative target governed by
[ADR-0052](0052-xev-primary-k8s-backup-target.md). The secure-storage host is not
part of the bulk-storage ownership unit and is not a prerequisite for the bulk
move.

Any future secure-storage move requires a separate decision covering unattended
availability, recovery authorization, failure-domain separation, import
ownership, validation, and rollback. It must not be inferred from the bulk
migration.

## Staging and Acceptance Contract

The secure/bulk policy split and secure-storage ownership decision are complete.
The remaining bulk-storage and dependent-service migration stays staged under
[ADR-0062](0062-xev-tank-storage-and-media-service-migration.md).

Before moving bulk ownership, verify the destination storage independently and
define a bounded rollback point. During an intermediate remote-service stage,
consumers must require the intended remote storage and fail safely when it is
unavailable, rather than write to an unintended local path. Move dependent
services separately, verifying data integrity, service behavior, monitoring,
and rollback after each stage. Preserve the independently recoverable backup
copy throughout the migration.

## Alternatives considered

### Move secure and bulk storage together

Rejected. The services need the bulk data plane, while a secure-storage move
would add unrelated availability, recovery, and failure-domain changes.

### Place the backup replica with its authoritative target

Rejected because the replica must remain in an independent host failure domain.

### Treat a future secure-storage move as part of this migration

Rejected. Such a move requires its own architecture and recovery review.

## Consequences

- Replaceable bulk capacity and secure recovery-oriented storage have distinct
  owners and lifecycle decisions.
- The bulk migration does not depend on moving secure storage.
- The Kubernetes backup replica remains separate from its authoritative target.
- Secure storage remains unavailable during maintenance of its owning host.
- A later secure-storage move remains possible through a separately approved
  decision.
