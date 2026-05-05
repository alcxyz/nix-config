# ADR-0017: k3s cluster topology for the current homelab phase

**Status:** Accepted
**Date:** 2026-04-26
**Updated:** 2026-05-02
**Applies to:** `hosts/nux`, `hosts/rpi0`, `hosts/xyz`, future `nex`, infrastructure

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
- `rpi0` — RK3399 SBC, 4 GB RAM, suitable for control-plane duty but not general workloads
- `xyz` — Ryzen 9 workstation, 64 GB RAM, suitable as opportunistic worker capacity but not a stable quorum member
- `nex` — future x86_64 NUC, not yet installed/configured
- `xev` — reserved for a later Ryzen 1700X machine, not part of the immediate step

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

### Cluster topology: current next step

Move from single-node k3s on `nux` to the following intermediate topology:

| Node | Hardware | Role | Scheduling |
|------|----------|------|------------|
| `nux` | Intel NUC, 32 GB | `server + worker` | normal workload host |
| `rpi0` | RK3399 SBC, 4 GB | `server` | tainted `NoSchedule` |
| `xyz` | Ryzen 9 workstation, 64 GB | `agent` | opportunistic / burst compute |

Notes:

- `rpi0` joins the control plane but is not intended to run normal workloads
- `xyz` adds x86_64 capacity immediately but is not counted as stable HA infrastructure
- this improves the cluster materially, but it is still not the final HA target

### Cluster topology: target after nex

Once `nex` is installed and added to `nix-config`, the intended stable topology is:

| Node | Hardware | Role | Scheduling |
|------|----------|------|------------|
| `nux` | Intel NUC, 32 GB | `server + worker` | normal workload host |
| `rpi0` | RK3399 SBC, 4 GB | `server` | tainted `NoSchedule` |
| `nex` | Intel NUC, 16-32 GB | `server + worker` | normal workload host |
| `xyz` | Ryzen 9 workstation, 64 GB | `agent` | opportunistic / burst compute |

At that point the cluster has the intended 3-server control plane, and can tolerate
loss of one control-plane node while keeping quorum.

## Migration order

### Already done

1. Install k3s on `nux`
2. Migrate the majority of application workloads from Docker Compose into k3s
3. Leave `Pi-hole` and `UniFi` outside the cluster intentionally

### Next step

1. Join `rpi0` as a k3s server
2. Apply a `NoSchedule` taint to keep `rpi0` off the normal workload path
3. Join `xyz` as a k3s agent
4. Verify scheduling, API health, and failover behavior of the 2-server + 1-agent intermediate state

### Later

1. Install/configure `nex`
2. Join `nex` as the third k3s server + worker
3. Rebalance stateful workloads and storage choices as needed
4. Optionally add `xev` as another agent

## Alternatives considered

### Move `Pi-hole` into k3s now

Rejected. DNS is more critical than the cluster itself and should stay independent
while the control plane is still maturing.

### Move `UniFi` into k3s now

Rejected. UniFi is better treated as a host-native service until the cluster reaches
its intended multi-server shape.

### Keep `rpi0` out of k3s until nex exists

Rejected. `rpi0` is available now and is a useful immediate control-plane member,
even if it is not a general workload host.

### Count `xyz` as part of the HA control plane

Rejected. `xyz` is a workstation and may reboot, suspend, or be busy. It is a good
agent, not a stable quorum node.

### Make nex only a worker

Rejected. The whole point of the future `nex` addition is to complete the
3-server control plane, not just add more worker capacity.

## Consequences

- **Better now:** immediate improvement over a single-node cluster once `rpi0` and
  `xyz` join
- **Still limited:** true control-plane HA still waits on `nex`
- **Safer networking:** `Pi-hole` and `UniFi` remain independent of cluster health
- **Mixed-role reality:** the homelab remains hybrid for a while:
  - k3s for most apps
  - host-native network services outside the cluster
- **Operational clarity:** the topology is now staged explicitly instead of pretending
  the original “everything still in Docker” context still applies
