# ADR-0017: k3s cluster topology for the current homelab phase

**Status:** Accepted (amended by ADR-0051, ADR-0060, and ADR-0061)
**Date:** 2026-04-26
**Updated:** 2026-08-20
**Applies to:** stable k3s servers, workstation agents, independent network services

## Context

Application workloads run in a multi-server k3s cluster. DNS must remain usable
when Kubernetes is unavailable, while the UniFi Network Application now ships
with and runs on the network gateway. Host-managed UniFi active/passive service
plans are retired by ADR-0060.

## Decision

Keep the network-critical control surfaces outside k3s:

### Host-native services

- Pi-hole and Unbound run as a two-host native NixOS resolver pair outside k3s.
- The gateway console owns the UniFi Network Application runtime.
- GitOps may manage selected UniFi desired state, but no general-purpose host
  runs an active or standby controller.

These services should not depend on the current cluster for availability.

### Cluster topology: current target

Run the steady-state three-server embedded-etcd topology on the more capable
stable machines:

| Node class | Role | Scheduling |
|------------|------|------------|
| stable servers | `server + worker` | normal workloads and control plane |
| workstations | no k3s role | host-native workloads only |
| resolver hosts | no k3s role | native DNS only |

The cluster keeps a three-server control plane and one-server failure tolerance.
The resolver pair remains intentionally outside k3s so LAN DNS does not depend
on cluster health.

## Migration order

The cluster migration and network-service separation are complete. ADR-0051
records the control-plane transition. ADR-0060 records the later controller and
resolver cutover.

## Alternatives considered

### Move `Pi-hole` into k3s now

Rejected. DNS is more critical than the cluster itself and should stay independent
while the control plane is still maturing.

### Run UniFi on a general-purpose host or in k3s

Superseded. The gateway console now owns the application lifecycle, removing
the need for a separate controller runtime.

### Keep `rpi0` out of k3s

Originally rejected before `nex` existed. Superseded by ADR-0051 after `xev`
became available as a stronger replacement server.

### Count `xyz` as part of the cluster

Rejected. `xyz` is a workstation and may reboot, suspend, or be busy. Its former
agent-only browser fallback role was retired by ADR-0061 after the operational
coupling outweighed the availability benefit.

### Make nex only a worker

Rejected. The whole point of the future `nex` addition is to complete the
3-server control plane, not just add more worker capacity.

## Consequences

- **Better now:** control-plane quorum runs on `xev`, `nux`, and `nex`
- **Still limited:** three embedded-etcd members tolerate one server failure,
  not two
- **Safer networking:** DNS and the gateway control plane remain independent of
  cluster health
- **Mixed-role reality:** the homelab remains hybrid for a while:
  - k3s for most apps
  - native resolvers and the gateway console outside the cluster
- **Operational clarity:** the topology is now staged explicitly instead of pretending
  the original “everything still in Docker” context still applies
