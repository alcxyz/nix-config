# ADR-0017: k3s cluster topology for home infrastructure

**Status:** Accepted
**Date:** 2026-04-26
**Applies to:** `hosts/nux`, `hosts/xyz`, infrastructure

## Context

nux currently runs ~50 Docker containers across ~20 services (Paperless x2, ERPNext, Nextcloud, Seafile, Forgejo, n8n, Leantime, HedgeDoc, Pi-hole, etc.) managed via individual docker-compose files. rpi0 runs lightweight network infrastructure (Pi-hole, Cloudflare tunnel, Traefik).

As the number of services grows, managing independent compose files becomes unwieldy. There is no resource visibility across services, no workload distribution, and no fault tolerance — losing nux means losing everything.

Additional hardware is available: a second NUC (NUC #2, i5-8259U, 16GB RAM, upgradeable), the xyz workstation (Ryzen 9 9950X, 64GB RAM), and xev (Ryzen 1700X, 32GB RAM). These could contribute compute but have varying reliability — xyz and xev may be rebooted or powered off.

## Decision

Adopt k3s as the container orchestration layer, replacing Docker Compose across all services. The cluster topology:

**Server nodes (etcd quorum — 3 nodes, can lose 1):**

| Node | Hardware | RAM | Role |
|------|----------|-----|------|
| rpi0 | RK3399 SBC | 4GB | Server only — tainted `NoSchedule`, dedicated control plane member |
| nux | Intel i5-8259U NUC | 32GB | Server + agent — primary workhorse |
| NUC #2 | Intel i5-8259U NUC | 16-32GB | Server + agent — second workhorse |

**Agent nodes (ephemeral compute, no etcd):**

| Node | Hardware | RAM | Notes |
|------|----------|-----|-------|
| xyz | Ryzen 9 9950X | 64GB | Workstation, may reboot — burst compute |
| xev | Ryzen 1700X | 32GB | Mid-tower, may be powered off — extra capacity |

rpi0 is aarch64; all other nodes are x86_64. The k3s control plane is multi-arch. Workload images that need to run on rpi0 (none planned — it's NoSchedule) would need multi-arch builds.

**Migration order:**
1. Install k3s on nux (single server + agent), migrate workloads incrementally — stateless first, stateful last
2. Join rpi0 as server (NoSchedule), join NUC #2 as server + agent — achieving 3-node etcd HA
3. Join xyz and xev as agents when convenient

**Supporting infrastructure:**
- **Storage:** `local-path` provisioner while single-node; Longhorn for replicated PVs once NUC #2 joins
- **Ingress:** k3s built-in Traefik ingress controller. During migration, k3s Traefik binds to high ports (8080/8443 via `HelmChartConfig`) so Docker Traefik retains 80/443 for external ingress. Docker Traefik proxies to k3s NodePorts for migrated services needing external access. After full cutover, k3s Traefik claims 80/443 and Docker Traefik is removed.
- **Secrets:** SOPS operator or Sealed Secrets with existing age keys
- **GitOps:** Flux or ArgoCD, deployed from Forgejo/GitHub repos
- **Network infra:** Pi-hole and Cloudflare tunnel move into the cluster with rpi0 or stay as host services — decided per-service during migration

## Alternatives Considered

- **Stay on Docker Compose** — works today but no resource visibility, no multi-node scheduling, no fault tolerance. Operational overhead scales linearly with service count.
- **Full Kubernetes (kubeadm)** — heavier control plane, more operational burden. k3s is purpose-built for edge/homelab with the same API surface.
- **Docker Swarm** — simpler than k8s but effectively abandoned upstream. Smaller ecosystem, fewer tools, uncertain future.
- **Nomad** — capable orchestrator but smaller community, less tooling, would require learning a new ecosystem rather than leveraging existing Kubernetes knowledge.
- **VMs on xyz/xev for control plane** — adds complexity without real availability gain since VMs die with the host.
- **External Postgres datastore instead of embedded etcd** — viable for 2-node HA but unnecessary with 3 physical server nodes available.
- **RPi 3 B+ as 4th control plane** — 1GB RAM is too tight for k3s server, and 4 etcd nodes don't improve fault tolerance over 3 (quorum 3/4, still can only lose 1).

## Consequences

- **Easier:** Adding new services (just a manifest), resource monitoring, workload distribution across nodes, fault tolerance (survive single-node loss), declarative GitOps deployments.
- **Harder:** Initial migration of ~20 services from docker-compose to k8s manifests. Learning curve for k8s-native debugging. Mixed-arch awareness for any images that might schedule to rpi0.
- **Trade-off:** More infrastructure complexity (k3s, etcd, Longhorn) in exchange for operational capability that Docker Compose cannot provide at this scale.
- **Risk:** Migration is disruptive and must be done incrementally. Running Docker and k3s side-by-side on nux during transition is supported but adds temporary complexity.
