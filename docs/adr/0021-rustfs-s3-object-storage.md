# ADR-0021: RustFS as S3-compatible object storage

**Status:** Accepted
**Date:** 2026-04-26
**Applies to:** k3s cluster, infrastructure

## Context

The k3s cluster needs S3-compatible object storage for:
- Forgejo container registry backend (storing container images)
- Application storage (exports, artifacts)

Earlier versions of this ADR also listed database backup storage and the
Longhorn backup target. That responsibility has moved to the host-level,
ZFS-backed backup endpoint on `xyz`; see ADR-0039. In-cluster RustFS remains the
application object store, but it is not the only disaster-recovery target.

No object storage currently exists in the homelab infrastructure.

## Decision

Deploy RustFS as the S3-compatible object storage service inside the k3s cluster. RustFS is a Rust rewrite of MinIO with the same S3 API surface, deployed in standalone (single-node) mode initially.

**Deployment: in-cluster (k3s), not as a NixOS host service.**

Running inside k3s was chosen over running directly on NixOS because:
- When NUC #2 joins the cluster (ADR-0017), RustFS can be rescheduled to a healthy node if nux goes down. With Longhorn replicated PVs, data survives node failure — HA comes from the cluster for free.
- Running on a single NixOS host would require setting up RustFS-level replication separately, adding operational complexity outside the k8s management plane.
- The chicken-and-egg concern (k3s restart takes down S3, which Forgejo registry depends on) does not apply: RustFS uses the public `rustfs/rustfs` image from Docker Hub, not images from the Forgejo registry. k3s pulls it directly with no circular dependency.
- k3s etcd snapshots are written to local disk (`/var/lib/rancher/k3s/server/db/snapshots/`) and can be uploaded to RustFS by a host-level cron job without RustFS being a host service.

**Configuration:**
- Single-node standalone mode with hostPath storage on nux (Longhorn replicated PV when multi-node)
- API on port 9000, web console on port 9001
- Accessible at `s3.alc.xyz` (API) and `s3-console.alc.xyz` (web console)
- Buckets created per use case: `forgejo`, `backups`, `longhorn`, etc. The
  `longhorn` bucket is retained for compatibility/testing, but the production
  Longhorn backup target should point at the host-level backup endpoint from
  ADR-0039.
- Used as Forgejo's storage backend for packages, LFS, and attachments

## Alternatives Considered

- **MinIO** — mature and battle-tested, but licensed under AGPLv3 which has copyleft implications. Heavier Go runtime with GC pauses. RustFS is API-compatible and a drop-in replacement.
- **Garage** — Rust-based, lightweight, designed for geo-distributed setups. Less mature ecosystem, different API surface from MinIO tooling. Overkill for single-site homelab.
- **SeaweedFS** — Go-based, optimised for many small files. More complex architecture (master + volume + filer servers). Not S3-native, adds a translation layer.
- **Ceph RGW** — enterprise-grade but extremely heavy for a homelab. Minimum 3 nodes recommended.
- **Cloud S3 (Backblaze B2, Wasabi)** — recurring cost, data leaves the network. Against the self-hosted principle for primary storage.
- **RustFS only on a NixOS host** — rejected for application object storage because it would tie Forgejo/Nextcloud/etc. to one host and bypass k3s scheduling. A separate host-level RustFS endpoint is now accepted for backups only in ADR-0039, because backups must sit outside the Longhorn/k3s dependency path.

## Consequences

- **Easier:** Unified S3 API for all storage needs. Forgejo, Longhorn, and applications all use the same endpoint. Web console for bucket management. HA path via k3s scheduling and Longhorn when multi-node.
- **Harder:** RustFS is still alpha (v1.0.0-alpha). May encounter bugs or breaking changes on upgrades. Acceptable risk for a homelab where data is also backed up externally. S3 availability is tied to k3s cluster health.
- **Trade-off:** Choosing an alpha project over a stable one (MinIO) for license and performance reasons. The S3 API compatibility means switching to MinIO later is trivial if RustFS proves unreliable.
