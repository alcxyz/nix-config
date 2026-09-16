# ADR-0039: xyz ZFS-backed S3 target for cluster backups

**Status:** Superseded by [ADR-0052](0052-xev-primary-k8s-backup-target.md)
**Date:** 2026-05-06
**Applies to:** host-level object storage and Kubernetes backup posture

## Context

Replicated Kubernetes storage improves workload mobility, but it is not an
independent backup. A backup target hosted by the same cluster storage stack
would share its failure path.

Detailed storage layout, endpoints, credentials, retention, and recovery
procedures are private in accordance with
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Decision

Provide a bounded, host-level S3-compatible target outside the Kubernetes and
cluster-storage dependency path. Keep it dedicated to backups; application
object storage remains a separate in-cluster service.

Enforce a storage bound so backup growth cannot consume unrelated host storage.
Defer application-aware database backup automation until the database topology
is decided in [ADR-0024](0024-shared-postgres-cluster.md).

ADR-0052 later superseded the target placement while retaining these dependency
and bounded-growth requirements.

## Alternatives Considered

**Use the in-cluster object store** — rejected because the backup target would
depend on the cluster and storage system it is intended to recover.

**Share unbounded host storage** — rejected because backup growth must fail in
a controlled scope rather than consume unrelated capacity.

**Add per-application database jobs immediately** — deferred because doing so
would prematurely encode a database topology that was still under review.

## Consequences

Cluster volumes can be copied to storage outside their runtime dependency path,
and capacity exhaustion is contained. The selected host remains a dependency
for new backup writes, motivating the later primary-and-replica design in
ADR-0052.
