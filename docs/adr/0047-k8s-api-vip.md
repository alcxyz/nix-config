# ADR-0047: Kubernetes API floating VIP

**Status:** Accepted
**Date:** 2026-05-12
**Applies to:** `hosts/nux`, `hosts/nex`, `hosts/rpi0`, `hosts/xyz`, `modules/nixos/services/k8s-api-vip`, `modules/nixos/virtualisation/k3s`, `nix-secrets/cluster-bootstrap/k3s-kubeconfig.yaml`, `gitops/pihole`

## Context

The k3s control plane now has three embedded-etcd server nodes:

- `nux` at `192.168.1.15`
- `nex` at `192.168.1.16`
- `rpi0` at `192.168.1.3`

The cluster can tolerate one server-node failure as long as two embedded-etcd
members remain available. Client access did not have the same property because
the shared kubeconfig pointed at `https://nux:6443`. If `nux` was down,
`kubectl` and joining agents targeted a dead host even when the control plane
still had quorum through `nex` and `rpi0`.

k3s binds the API server on `*:6443` on each server node. That makes a local
HAProxy listener on `VIP:6443` conflict with k3s on the same machines unless the
k3s bind behavior is changed. The cluster does not need request distribution for
the Kubernetes API; it needs a stable endpoint that follows a healthy server.

The LAN already reserves `192.168.1.240-192.168.1.249` for MetalLB and keeps the
DHCP pool below that range. `192.168.1.250` is outside both DHCP and the MetalLB
pool.

## Decision

Use a host-managed floating VIP for the Kubernetes API:

```text
k8s-api.local -> 192.168.1.250
192.168.1.250:6443 -> local k3s API on the current VIP holder
```

`nux`, `nex`, and `rpi0` run keepalived through a reusable NixOS module:

- VRRP is unicast between the three server LAN addresses.
- The VIP is assigned to the LAN interface on one server at a time.
- keepalived tracks the local k3s API TCP listener on `127.0.0.1:6443`.
- `nux` has the highest election priority, followed by `nex`, then `rpi0`.
- `nopreempt` avoids moving the VIP back just because a higher-priority node
  returns after a failover.

The k3s module supports declarative `tlsSans`, and the server nodes include:

- `k8s-api.local`
- `192.168.1.250`

Kubernetes clients and joining agents should use
`https://k8s-api.local:6443`. Host `/etc/hosts` entries provide local resolution
for Nix-managed k3s nodes while the Pi-hole record provides LAN-wide resolution.

## Alternatives Considered

**Keep `https://nux:6443`** - rejected because it makes `nux` a client access
single point of failure even after the control plane gained quorum redundancy.

**DNS round-robin across `nux`, `nex`, and `rpi0`** - rejected because clients and
resolvers do not provide reliable health-aware failover for Kubernetes API
traffic.

**HAProxy plus keepalived on the control-plane nodes** - rejected for this
cluster because k3s already binds `*:6443` on each server. A proxy would need a
different port, a separate host, or a changed k3s bind strategy. None is needed
for the desired failover behavior.

**kube-vip in Kubernetes** - rejected for the API endpoint because this endpoint
is part of reaching and recovering the control plane. A host-managed service is
easier to reason about when Kubernetes itself is degraded.

**Use a dedicated load-balancer host** - rejected because it would add another
machine dependency. The server nodes can host the VIP directly.

## Consequences

If one server node fails, clients keep using `k8s-api.local` and the VIP moves to
another healthy server as long as the cluster still has etcd quorum.

This does not change etcd quorum math. With three server nodes, the cluster still
needs two server nodes online. A future fourth server should not be added
casually because four etcd members still tolerate only one failure. Moving beyond
three server nodes should be a deliberate five-member control-plane decision.

Rollout order matters:

1. Deploy the keepalived VIP and k3s TLS SANs to `nux`.
2. Verify `192.168.1.250:6443` serves the API and the certificate covers
   `k8s-api.local`.
3. Deploy `nex` and `rpi0` with `serverAddr = "https://k8s-api.local:6443"`.
4. Deploy agent hosts such as `xyz` with the same stable server address.
5. Apply the Pi-hole DNS record and update shared kubeconfig consumers.
6. Test failover by stopping keepalived on the current VIP holder and verifying
   `kubectl get nodes` still works through `k8s-api.local`.
