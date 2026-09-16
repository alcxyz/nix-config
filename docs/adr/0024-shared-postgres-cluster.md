# ADR-0024: Shared Postgres cluster for k8s services

**Status:** Proposed
**Date:** 2026-04-26
**Applies to:** Kubernetes database infrastructure

## Context

A separate database instance per application duplicates resource overhead,
monitoring and backup lifecycle work. Consolidation can reduce this duplication,
but also increases the shared failure domain. This proposal records that tradeoff;
it is not evidence of the current deployment state.

## Decision (proposed)

Propose consolidating to a shared PostgreSQL cluster with one database per service and
credentials scoped to each service's database. Choose the database topology
before standardizing application-aware backups so backup automation does not
prematurely commit to an obsolete instance model.

The proposal does not authorize consolidation or select an operator. Runtime
ownership, adoption and acceptance belong in the GitOps repository and live
Forgejo issues.

## Qualification

Any approved migration needs independent application acceptance, recoverable
state transitions and validated application-aware restores. Backup storage must
follow [ADR-0052](0052-xev-primary-k8s-backup-target.md), outside the database's
cluster-storage dependency path. [ADR-0039](0039-xyz-zfs-s3-backup-target.md)
is the superseded historical backup placement.

Concrete migration and recovery procedures belong to private operational
documentation under
[nix-secrets ADR-0003](https://git.alc.xyz/alcxyz/nix-secrets/src/branch/dev/docs/adr/0003-public-nix-config-redaction.md).

## Alternatives Considered

- **Per-service PostgreSQL:** retains independent instance lifecycles but
  duplicates resources and administration.
- **Operator-managed PostgreSQL:** may provide shared lifecycle, backup and
  failover mechanisms, at the cost of another control-plane dependency.
- **Host-native PostgreSQL:** avoids Kubernetes database lifecycle management,
  but needs its own availability and recovery design.

## Consequences

Consolidation could simplify monitoring, pooling and backup ownership. An outage
or maintenance event could affect multiple applications at once. Kubernetes
scheduling and replicated storage alone do not establish database availability
or recovery correctness.
