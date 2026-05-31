# ADR-0017: k3s cluster topology for the current homelab phase

**Status:** Accepted (amended by ADR-0051)
**Date:** 2026-04-26
**Updated:** 2026-05-31
**Applies to:** `hosts/xev`, `hosts/nux`, `hosts/nex`, `hosts/rpi0`, `hosts/xyz`, infrastructure

## Context

The original migration plan assumed most services still lived in Docker Compose on
`nux`. That is no longer true.

The current state is:

- most application workloads have already moved into the single-node k3s cluster on `nux`
- Docker on `nux` is now mostly legacy/host-infra residue rather than the primary app platform
- the intentionally host-native services left outside the cluster are:
  - `Pi-hole`
  - `UniFi Network Application`
- `Pi-hole` is more critical than the cluster itself and should remain independent of it
- `UniFi` is useful but less mission-critical than DNS and can remain host-native for now

So the real question is no longer “should we adopt k3s?” It is “how do we evolve the
existing single-node k3s install into a more resilient topology without dragging
network-critical services into the cluster?”

Available hardware:

- `nux` — x86_64 NUC, 32 GB RAM, current single-node k3s server and main workload host
- `rpi0` — RK3399 SBC, 4 GB RAM, suitable for host-native DNS and standby network services
- `xyz` — Ryzen 9 workstation, 64 GB RAM, suitable as opportunistic worker capacity but not a stable quorum member
- `nex` — future x86_64 NUC, not yet installed/configured
- `xev` — Ryzen 1700X server, suitable for stable workloads, Longhorn, and control-plane duty

## Decision

Keep `Pi-hole` and `UniFi` outside k3s, and evolve the cluster in stages:

### Host-native services

- `Pi-hole` remains outside k3s
  - `nux` stays primary DNS
  - `rpi0` stays secondary DNS
- `UniFi` remains outside k3s
  - `nux` stays the active controller
  - `rpi0` remains the standby/fallback location

These services should not depend on the current cluster for availability.

### Cluster topology: current target

Run the steady-state three-server embedded-etcd topology on the more capable
stable machines:

| Node | Hardware | Role | Scheduling |
|------|----------|------|------------|
| `xev` | Ryzen 1700X server | `server + worker` | normal workload host |
| `nux` | Intel NUC, 32 GB | `server + worker` | normal workload host |
| `nex` | Intel NUC, 16-32 GB | `server + worker` | normal workload host |
| `xyz` | Ryzen 9 workstation, 64 GB | `agent` | opportunistic / burst compute |
| `rpi0` | RK3399 SBC, 4 GB | no k3s role | host-native DNS and standby UniFi |

The cluster keeps a three-server control plane and can tolerate loss of one
control-plane node while keeping quorum. `rpi0` remains intentionally outside
k3s so DNS and standby network services do not depend on cluster health and do
not compete with k3s server state on a small root filesystem.

## Migration order

### Already done

1. Install k3s on `nux`
2. Migrate the majority of application workloads from Docker Compose into k3s
3. Leave `Pi-hole` and `UniFi` outside the cluster intentionally

### Current migration

1. Promote `xev` from stable agent to k3s server-worker.
2. Verify the four-member transition state is healthy.
3. Drain and remove `rpi0` from Kubernetes and embedded etcd.
4. Deploy `rpi0` as host-native DNS/Pi-hole and standby UniFi only.

## Alternatives considered

### Move `Pi-hole` into k3s now

Rejected. DNS is more critical than the cluster itself and should stay independent
while the control plane is still maturing.

### Move `UniFi` into k3s now

Rejected. UniFi is better treated as a host-native service until the cluster reaches
its intended multi-server shape.

### Keep `rpi0` out of k3s

Originally rejected before `nex` existed. Superseded by ADR-0051 after `xev`
became available as a stronger replacement server.

### Count `xyz` as part of the HA control plane

Rejected. `xyz` is a workstation and may reboot, suspend, or be busy. It is a good
agent, not a stable quorum node.

### Make nex only a worker

Rejected. The whole point of the future `nex` addition is to complete the
3-server control plane, not just add more worker capacity.

## Consequences

- **Better now:** control-plane quorum runs on `xev`, `nux`, and `nex`
- **Still limited:** three embedded-etcd members tolerate one server failure,
  not two
- **Safer networking:** `Pi-hole` and `UniFi` remain independent of cluster health
- **Mixed-role reality:** the homelab remains hybrid for a while:
  - k3s for most apps
  - host-native network services outside the cluster
- **Operational clarity:** the topology is now staged explicitly instead of pretending
  the original “everything still in Docker” context still applies
