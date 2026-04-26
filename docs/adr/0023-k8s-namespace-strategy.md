# ADR-0023: Domain-based Kubernetes namespace strategy

**Status:** Accepted
**Date:** 2026-04-26
**Applies to:** k3s cluster, `gitops/k8s/`

## Context

The initial k8s migration (ADR-0017) created one namespace per service — 19 namespaces for 19 services. This mirrors the Docker Compose model where each service is fully isolated, but it misses the point of namespaces in Kubernetes.

With one-namespace-per-service:
- Namespaces provide no grouping value — they're just prefixes
- Related services (e.g. two Paperless instances, or multiple annae.tattoo services) can't share network policies, resource quotas, or RBAC rules
- `kubectl get pods` requires knowing which of 19 namespaces to query
- Cross-service communication always requires FQDN (`svc.namespace.svc.cluster.local`) even between tightly related services

The business already has a natural domain structure, reflected in the Leantime project hierarchy (ALC.XYZ AS — Platform, Operations, client projects). Namespaces should mirror this.

## Decision

Group services into domain-based namespaces aligned with the Leantime project structure. Services within a namespace share a business domain and are likely to share RBAC, network policies, and resource quotas.

| Namespace | Services | Domain |
|-----------|----------|--------|
| `platform` | forgejo, hedgedoc, linkwarden, n8n, leantime, uptime-kuma | Internal platform tools (ALC.XYZ AS — Platform) |
| `infrastructure` | rustfs, cloudflared, pihole, unifi | Network and storage infrastructure |
| `documents` | paperless-arq, paperless-arquivo | Document management (ALC.XYZ AS — Operations) |
| `storage` | nextcloud, seafile | File storage and collaboration |
| `annae` | annae-sales, booking | annae.tattoo client services |
| `madideal` | erpnext | Madideal client (ecommerce ERP) |
| `custom` | telegram-bot, valuta-quotes | Custom-built lightweight services |

7 namespaces instead of 19. New services are added to the namespace matching their business domain.

**Naming convention:**
- Use the business domain name, not a technical category
- Client namespaces use the client's short name (e.g. `annae`, `madideal`)
- Internal namespaces use their function (`platform`, `infrastructure`, `documents`, `storage`, `custom`)

**Within a namespace**, services that need their own database or secrets still get their own Deployment, Service, Secret, etc. — the namespace groups them, it doesn't merge them.

## Alternatives Considered

- **One namespace per service** (current) — maximum isolation but no grouping benefit. 19+ namespaces to manage with no shared policies. Operationally noisy.
- **Single default namespace** — simplest, but no isolation at all. Can't apply per-domain resource quotas or RBAC. Doesn't scale.
- **Technical grouping** (databases, web-apps, cron-jobs) — groups by implementation detail rather than business domain. A database namespace containing Postgres instances for unrelated clients makes no operational sense.
- **One namespace per Leantime project** — too fine-grained (mirrors the per-service problem). Leantime projects don't always map 1:1 to deployment domains.

## Consequences

- **Easier:** `kubectl get pods -n annae` shows everything for that client. Network policies and resource quotas apply per domain. RBAC can be scoped to a business domain (e.g. future collaborator sees only their client namespace). Fewer namespaces to manage.
- **Harder:** Services that were in their own namespace now share one — name collisions are possible (e.g. two services both wanting a ConfigMap called `config`). Mitigated by prefixing resource names with the service name, which is already standard practice.
- **Trade-off:** Less isolation between services in the same namespace. Acceptable because services within a domain are already related and share the same trust boundary. Cross-domain isolation (e.g. between `annae` and `madideal`) is preserved.
- **Migration impact:** All manifests on the `k8s-migration-prep` branch need their namespace references updated. Infrastructure namespaces.yaml must be rewritten. Existing RustFS deployment moves from `rustfs` namespace to `infrastructure`.
