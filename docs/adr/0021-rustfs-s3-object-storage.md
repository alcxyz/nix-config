# ADR-0021: RustFS as S3-compatible object storage

**Status:** Accepted
**Date:** 2026-04-26
**Applies to:** Application object storage

## Context

Applications need a shared S3-compatible storage interface. Application storage
and recovery storage have different availability requirements: a backup target
must remain outside the storage dependency path it protects.

## Decision

Use RustFS for application object storage. The initial standalone Kubernetes
deployment remains the active service while a native, distributed three-member
service is staged on independent host storage. The native service runs under
systemd with a dedicated service identity and explicit mounted-storage and
credential-file dependencies. Its package and topology are selected by the
caller; the public module contains no private host placement or secret wiring.

Prepare and copy application objects, verify basic S3 operations with the
actual consumers, and retain the existing endpoint for rollback during
cutover. Qualify physical node-loss recovery and healing separately before
claiming high availability. A distributed object store does not replace
independent backups or restore qualification.

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
- **Host-only application storage:** initially deferred because it requires a
  separate host availability strategy. Native distributed RustFS now provides
  that strategy without coupling object availability to Kubernetes storage.

## Consequences

Applications retain an S3-compatible interface. During staging, availability
still depends on the current Kubernetes service. After promotion, availability
depends on the native member topology and host storage instead. The original
choice accepted product maturity risk; upgrades and migration need compatibility
and recovery validation. API compatibility alone does not establish a safe
migration.
