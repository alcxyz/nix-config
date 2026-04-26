# ADR-0021: RustFS as S3-compatible object storage

**Status:** Accepted
**Date:** 2026-04-26
**Applies to:** k3s cluster, infrastructure

## Context

The k3s cluster needs S3-compatible object storage for:
- Forgejo container registry backend (storing container images)
- Database backup storage
- Longhorn backup target (when multi-node HA is set up per ADR-0017)
- Application storage (exports, artifacts)

No object storage currently exists in the homelab infrastructure.

## Decision

Deploy RustFS as the S3-compatible object storage service. RustFS is a Rust rewrite of MinIO with the same S3 API surface, deployed in standalone (single-node) mode initially.

**Configuration:**
- Single-node standalone mode with hostPath storage on nux
- API on port 9000, web console on port 9001
- Accessible at `s3.alc.xyz` (API) and `s3-console.alc.xyz` (web console)
- Buckets created per use case: `forgejo-packages`, `backups`, `longhorn`, etc.

## Alternatives Considered

- **MinIO** — mature and battle-tested, but licensed under AGPLv3 which has copyleft implications. Heavier Go runtime with GC pauses. RustFS is API-compatible and a drop-in replacement.
- **Garage** — Rust-based, lightweight, designed for geo-distributed setups. Less mature ecosystem, different API surface from MinIO tooling. Overkill for single-site homelab.
- **SeaweedFS** — Go-based, optimised for many small files. More complex architecture (master + volume + filer servers). Not S3-native, adds a translation layer.
- **Ceph RGW** — enterprise-grade but extremely heavy for a homelab. Minimum 3 nodes recommended.
- **Cloud S3 (Backblaze B2, Wasabi)** — recurring cost, data leaves the network. Against the self-hosted principle for primary storage.

## Consequences

- **Easier:** Unified S3 API for all storage needs. Forgejo, Longhorn, and applications all use the same endpoint. Web console for bucket management.
- **Harder:** RustFS is still alpha (v1.0.0-alpha). May encounter bugs or breaking changes on upgrades. Acceptable risk for a homelab where data is also backed up externally.
- **Trade-off:** Choosing an alpha project over a stable one (MinIO) for license and performance reasons. The S3 API compatibility means switching to MinIO later is trivial if RustFS proves unreliable.
