# ADR-0021: RustFS as S3-compatible object storage

**Status:** Accepted
**Date:** 2026-04-26
**Applies to:** Kubernetes application object storage

## Context

Applications need a shared S3-compatible storage interface. Application storage
and recovery storage have different availability requirements: a backup target
must remain outside the storage dependency path it protects.

## Decision

Use RustFS for application object storage inside Kubernetes, initially in
standalone mode. Kubernetes owns scheduling and the persistent-volume lifecycle.
Replicated volumes can support recovery from node loss, but neither replication
nor rescheduling substitutes for independent backups or restore qualification.

Keep backup storage separate under
[ADR-0052](0052-xev-primary-k8s-backup-target.md).
[ADR-0039](0039-xyz-zfs-s3-backup-target.md) records the superseded first placement
of that backup role. Do not use the application object store as its own sole
recovery target.

Concrete deployment, access and recovery details belong to private operational
documentation under
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Alternatives Considered

- **MinIO:** considered for its established S3 ecosystem; licensing and
  implementation tradeoffs motivated the original RustFS choice.
- **Garage:** considered for distributed object storage, beyond the initial
  single-site requirement.
- **SeaweedFS or Ceph RGW:** considered, but their additional storage components
  exceed the intended initial operational scope.
- **Cloud object storage:** introduces recurring cost and an external dependency
  for primary application storage.
- **Host-only application storage:** bypasses Kubernetes scheduling and requires
  a separate host availability strategy. Host-level storage remains appropriate
  for the independent backup role.

## Consequences

Applications share an S3-compatible interface, while application object-store
availability depends on Kubernetes health. The original choice accepted product
maturity risk; upgrades and any replacement need compatibility and recovery
validation. API compatibility alone does not establish a safe migration.
