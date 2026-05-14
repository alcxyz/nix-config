# ADR-0045: xev and xps Kubernetes node onboarding

**Status:** Accepted (xev skeleton added; runtime onboarding in progress)
**Date:** 2026-05-11
**Applies to:** `inventory.nix`, `hosts/xev/`, `hosts/xps/`, `modules/nixos/virtualisation/k3s`, `modules/nixos/virtualisation/longhorn-prereqs`, gitops cluster manifests

## Context

The Kubernetes cluster currently has:

- `nux` - k3s server, embedded etcd, schedulable stable worker, Longhorn storage
- `nex` - k3s server, embedded etcd, schedulable stable worker, Longhorn storage
- `rpi0` - k3s server, embedded etcd, control-plane-only, tainted
  `NoSchedule`, excluded from normal workloads and Longhorn storage
- `xyz` - k3s agent, schedulable but labeled `workload-class=ephemeral`,
  workload-only for selected pinned workloads, not a normal Longhorn storage
  node

The gitops repo documents the Longhorn and autoscaling posture:

- Longhorn normal storage started on eligible amd64 nodes, initially `nux` and
  `nex`.
- `xyz` is workload-only initially.
- `rpi0` is excluded from normal storage and workload scheduling.
- Metrics coverage and autoscaling policy assume every schedulable node has
  kubelet metrics reachability.

`xev` is planned as the next full-capability Kubernetes node. `xps` may also
join later, but it is a Dell XPS 15-inch laptop with NVIDIA hardware and its
role is not yet decided.

## Decision

Onboard `xev` as a stable Kubernetes worker and Longhorn-eligible node, but do
not make it an embedded etcd server unless a separate control-plane expansion
decision accepts moving from three to five server members.

For `xev`:

- join k3s as an agent by default
- label as `workload-class=stable`
- enable Longhorn prerequisites
- allow Longhorn disk scheduling only after disk, power, cooling, and backup
  capacity are confirmed
- include kubelet metrics firewall access
- include Netbird if remote administration or mesh access is useful
- add a native Forgejo Actions runner only after node capacity and Docker
  policy are confirmed
- update gitops node/storage docs after the node is live

For `xps`:

- prepare as a laptop workstation first
- handle NVIDIA through the existing NVIDIA hardware module or a laptop-specific
  variant
- do not join Kubernetes by default
- decide separately whether it is:
  - a normal workstation only
  - an ephemeral k3s worker
  - a stable k3s worker
  - a GPU-capable workload node
- do not schedule Longhorn storage on it while its availability, suspend
  behavior, Wi-Fi reliability, and travel/offline pattern are unknown

Kubernetes onboarding gates for either host:

1. Host builds from this flake with a minimal NixOS configuration.
2. Host secrets exist in `nix-secrets`, including SSH host age recipient and
   k3s token access.
3. SSH access and rebuild/deploy path works from `xyz`.
4. k3s joins successfully and reports the expected role and labels.
5. Metrics Server can scrape kubelet on the node.
6. Longhorn prerequisites pass before any storage scheduling is enabled.
7. Gitops docs and node inventories are updated after the node is observed
   live.

## Implementation Status

Prepared in this repository:

- `stable-agent` exists as a Kubernetes role for future schedulable stable
  worker nodes
- `k8s-worker` exists as a host role for future Linux cluster workers
- `laptop-workstation` exists as a host role for `xps` while Kubernetes
  membership remains undecided
- `alc.host.k8s` exposes derived role, schedulability, labels, taints, and
  extra flags for future host modules and checks

Implemented for `xev`:

- `xev` is present in `inventory.nix` as `role = "k8s-worker"` and
  `k8sRole = "stable-agent"`
- `hosts/xev/` contains a buildable NixOS skeleton based on the live hardware
  scan from `192.168.1.13`
- the skeleton joins k3s as an agent and enables Longhorn host prerequisites

Not implemented yet:

- `xps` is not present in `inventory.nix`
- no `hosts/xps/` NixOS skeleton exists
- no Longhorn storage scheduling has been enabled for either host
- no gitops node/storage inventory has been updated for either host

The next implementation step is to finish `xev` secrets, deploy the managed
generation, confirm SSH access, verify the k3s agent joins with the expected
stable label, confirm Metrics Server reachability, and validate Longhorn
prerequisites before enabling storage scheduling. `xps` should remain
workstation-first until its suspend, NVIDIA, Wi-Fi, and availability behavior
are known.

## Follow-up Issues

- [#75](https://git.alc.xyz/alcxyz/nix-config/issues/75) Onboard `xev` as a
  stable k3s worker candidate.
- [#76](https://git.alc.xyz/alcxyz/nix-config/issues/76) Prepare `xps` as a
  workstation host and decide its Kubernetes role separately.

## Alternatives Considered

**Make `xev` a k3s server-worker immediately** - rejected for now. The current
server set already has three embedded etcd members. Adding one server would
create a four-member etcd cluster, which is not the desired failure-domain
shape. If more control-plane capacity is needed, add two servers and move to a
five-member decision deliberately.

**Treat `xev` like `xyz`** - rejected. `xyz` is intentionally labeled
`ephemeral` and keeps some host-local media/GPU duties. `xev` is intended to
increase normal cluster capacity.

**Let `xps` join Kubernetes immediately because it has useful hardware** -
rejected. Laptop power state, NVIDIA driver behavior, Wi-Fi, and offline
mobility can make it a poor default cluster dependency. It can still become an
ephemeral or GPU node after a separate decision.

**Enable Longhorn storage on every amd64 node by default** - rejected. Storage
nodes need stable power, stable network, sufficient disk, and clear backup and
capacity expectations. This is especially important for laptops.

## Consequences

`xev` improves cluster workload and possibly storage capacity without changing
control-plane quorum.

The k8s role model needs a stable-agent role distinct from the current
ephemeral `agent` role.

The gitops repo remains the runtime source for Kubernetes workload placement,
but Nix owns host readiness: kernel, firewall, k3s, Longhorn prerequisites,
Netbird, and node labels.

`xps` remains useful as a NixOS workstation even if it never becomes a cluster
node.
