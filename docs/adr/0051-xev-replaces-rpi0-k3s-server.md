# ADR-0051: xev replaces rpi0 as a k3s server

**Status:** Accepted
**Date:** 2026-05-31
**Applies to:** `inventory.nix`, `hosts/xev`, `hosts/rpi0`, `hosts/nux`, `hosts/nex`, `modules/nixos/services/k8s-api-vip`, k3s control-plane topology

## Context

The k3s control plane reached a three-server embedded-etcd shape with `nux`,
`nex`, and `rpi0`. `rpi0` was useful as an early control-plane-only member, but
it is an embedded ARM board with a small root filesystem. Running NixOS, k3s
server state, etcd snapshots, host-native DNS, and standby UniFi on that root
disk creates recurring storage pressure.

`xev` is now installed, stable, Longhorn-eligible, and already carries normal
cluster workloads as a stable k3s agent. It has substantially more CPU, memory,
and storage headroom than `rpi0`.

## Decision

Move the steady-state k3s server set from:

- `nux`
- `nex`
- `rpi0`

to:

- `xev`
- `nux`
- `nex`

`xev` becomes a `server-worker` node and participates in the host-managed
Kubernetes API VIP. `rpi0` leaves k3s and no longer participates in embedded
etcd or keepalived for the Kubernetes API.

`rpi0` remains a host-native network-services node for DNS/Pi-hole and standby
UniFi. Those services stay outside Kubernetes so local DNS does not depend on
cluster health.

## Rollout Order

1. Verify all current etcd endpoints are healthy.
2. Take an on-demand etcd snapshot.
3. Promote `xev` from k3s agent to k3s server-worker and verify it joins etcd.
4. Drain `rpi0` and remove its etcd membership.
5. Deploy the final NixOS topology: VIP peers are `xev`, `nux`, and `nex`;
   `rpi0` has k3s disabled.
6. Verify node readiness, etcd health, Kubernetes API VIP failover posture,
   host services on `rpi0`, and failed-unit state on affected hosts.

## Consequences

The control plane keeps three embedded-etcd members and the same one-server
failure tolerance, but moves quorum off the most constrained host.

`rpi0` no longer stores k3s server state or scheduled etcd snapshots, reducing
root filesystem pressure and recovery complexity.

`xev` now carries both normal workloads and control-plane quorum, so it should
be treated as a stable server dependency rather than only worker capacity.
