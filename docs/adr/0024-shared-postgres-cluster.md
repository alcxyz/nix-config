# ADR-0024: Shared Postgres cluster for k8s services

**Status:** Proposed
**Date:** 2026-04-26
**Applies to:** k3s cluster, database infrastructure

## Context

The Docker Compose setup runs a separate Postgres container per service (hedgedoc-db, linkwarden-db, leantime-db, forgejo-db, etc.). Each is a full Postgres instance consuming ~50-100MB RAM at idle, with its own backup lifecycle.

The initial k8s migration preserves this pattern — each service's manifests include a dedicated Postgres StatefulSet. This gets the services running quickly but carries the same waste:
- ~8 Postgres instances for ~8 services, each independently managed
- No shared connection pooling, no shared backup strategy
- Memory overhead multiplied per instance

The Longhorn migration makes this more urgent. Before adding a full set of
database dump CronJobs, the database topology should be decided. Otherwise the
backup implementation would cement the current per-service database model and
duplicate schedules, credentials, restore procedures, and monitoring.

## Decision (proposed)

Consolidate to a single shared Postgres cluster (e.g. CloudNativePG or a simple StatefulSet) in the `infrastructure` namespace, with one database per service. Services connect via credentials scoped to their own database.

**Not yet implemented.** The current migration uses per-service Postgres to avoid blocking the Docker→k8s migration. This ADR captures the intent to consolidate once the migration is complete.

## Migration path

1. Complete Docker→k8s migration with per-service Postgres (current)
2. Deploy shared Postgres in `infrastructure` namespace
3. Migrate databases one at a time: pg_dump from per-service instance, pg_restore into shared cluster, update service config to point to shared cluster
4. Remove per-service Postgres StatefulSets
5. Add app-aware backup jobs against the chosen database topology, writing to
   the host-level backup target from ADR-0039.

## Alternatives Considered

- **Keep per-service Postgres** — works, but wastes memory and complicates backup strategy. Acceptable for a small homelab but doesn't scale well.
- **CloudNativePG operator** — production-grade, handles HA, backups, failover. May be overkill for a single-node homelab but worth evaluating when multi-node.
- **External Postgres on NixOS host** — avoids k8s complexity for the database layer. But ties the database to a single host, losing the HA path from k8s scheduling.

## Consequences

- **Easier:** Single backup target, single monitoring point, lower memory footprint, connection pooling.
- **Harder:** Shared failure domain — if the Postgres cluster goes down, all services go down. Mitigated by k8s scheduling and Longhorn replication when multi-node.
- **Trade-off:** Operational simplicity vs blast radius. Acceptable for a homelab where all services already share the same physical host.
