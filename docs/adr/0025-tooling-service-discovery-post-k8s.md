# ADR-0025: Tooling service discovery after Docker-to-k8s migration

**Status:** Accepted
**Date:** 2026-04-27
**Applies to:** `gitops/nux/*/config.env`, `gitops/tools/`, local CLI tooling

## Context

All services migrated from Docker Compose to k8s (see gitops#21–#36). Docker Compose
provided implicit DNS resolution between containers on the same network — tools could
reach `leantime:8080`, `telegram-bot:8080`, `leantime-db:3306`, etc.

Post-migration, these Docker DNS names no longer resolve. Local tooling (scripts, bots,
CLIs invoked via `direnv exec`) that depended on Docker service names is broken.

Three categories of access patterns need updating:

1. **HTTP API access** — tools calling service REST/JSON-RPC APIs (leantime-bot, nssupply)
2. **Database access** — tools running SQL via `docker exec` or SSH tunnel to container IP
3. **Inter-service routing** — k8s configmaps referencing backends by Docker name

## Decision

Use **public URLs for HTTP API access** from outside the cluster, and **k8s FQDNs for
inter-service communication** within the cluster.

### Outside the cluster (local tooling, `direnv exec`, CI)

- Use the public URL (e.g., `https://time.alc.xyz`) for API calls. These route through
  Cloudflare tunnel → cloudflared → k8s service. No TLS or DNS issues.
- For database access, use `kubectl port-forward` to the database pod, then connect to
  `localhost:<forwarded-port>`. This replaces `docker exec` and SSH tunnel patterns.

### Inside the cluster (k8s configmaps, pod-to-pod)

- Use short service names (`leantime-db:3306`) when source and target are in the same
  namespace. Kubernetes DNS resolves these automatically.
- Use FQDNs (`service.namespace.svc.cluster.local`) when crossing namespaces.

### Config files (`nux/*/config.env`)

These files serve dual duty: they were originally Docker Compose env files, and they're
also sourced by `.envrc` for local tooling. Update the URLs in these files to public URLs.
The Docker Compose files themselves are now dead — only the `.envrc` + `config.env` path
matters.

## Alternatives Considered

**kubectl proxy / port-forward for all access** — too cumbersome for simple API calls
that work fine over the public URL. Reserve port-forward for database access only.

**Ingress for databases** — exposing MariaDB/Postgres via Traefik is a security risk and
unnecessary complexity. Port-forward is simpler and safer.

**Remove `nux/` Docker dirs entirely** — premature. The `.envrc` files still provide
useful context (secrets decryption, env setup) for local tooling. Clean up later when
tooling is fully migrated.

## Consequences

- Local tooling works again without Docker running
- `docker` binary is no longer required on dev machines for routine operations
- Database access requires `kubectl` access (already available via k3s kubeconfig)
- Public URLs add a network hop (Cloudflare tunnel) but latency is negligible for tooling
- Config files in `nux/*/` become slightly misleading (they're not Docker configs anymore)
  but renaming them is churn with no benefit right now
