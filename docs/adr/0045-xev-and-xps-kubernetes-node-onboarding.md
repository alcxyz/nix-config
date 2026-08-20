# ADR-0045: xev and xps Kubernetes node onboarding

**Status:** Accepted (xev promoted to k3s server; xps workstation-only for now)
**Date:** 2026-05-11
**Applies to:** `inventory.nix`, `hosts/xev/`, `hosts/xps/`, `modules/nixos/virtualisation/k3s`, `modules/nixos/virtualisation/longhorn-prereqs`, Forgejo runner services, gitops cluster manifests

## Context

The Kubernetes cluster currently has:

- `nux` - k3s server, embedded etcd, schedulable stable worker, Longhorn storage
- `nex` - k3s server, embedded etcd, schedulable stable worker, Longhorn storage
- `xev` - k3s server, embedded etcd, schedulable stable worker, Longhorn
  storage, native Forgejo runner
- `rpi0` - primary host-native DNS/Pi-hole, outside k3s
- `xyz` - k3s agent, schedulable but labeled `workload-class=ephemeral`,
  workload-only for selected pinned workloads, not a normal Longhorn storage
  node

The gitops repo documents the Longhorn and autoscaling posture:

- Longhorn normal storage started on eligible amd64 nodes, initially `nux` and
  `nex`.
- `xyz` is workload-only initially.
- `rpi0` is excluded from k3s.
- Metrics coverage and autoscaling policy assume every schedulable node has
  kubelet metrics reachability.

`xev` is the next full-capability Kubernetes node. `xps` is a Dell XPS 15-inch
laptop with NVIDIA hardware. It briefly joined as temporary worker capacity
during the 2026-05-20 storage swap, but USB Ethernet instability made it a poor
fit for the steady-state cluster.

## Decision

Onboard `xev` as a stable Kubernetes worker and Longhorn-eligible node. As
amended by [ADR-0051](0051-xev-replaces-rpi0-k3s-server.md), promote `xev` to a
k3s server-worker and remove `rpi0` from the k3s server set.

For `xev`:

- join k3s as a server-worker
- label as `workload-class=stable`
- enable Longhorn prerequisites
- allow Longhorn disk scheduling only after disk, power, cooling, and backup
  capacity are confirmed
- include kubelet metrics firewall access
- include Netbird if remote administration or mesh access is useful
- run a native Forgejo Actions runner in the primary Docker-capable pool after
  node capacity and Docker policy are confirmed
- update gitops node/storage docs after the node is live

For `xps`:

- prepare as a laptop workstation first
- handle NVIDIA through the existing NVIDIA hardware module or a laptop-specific
  variant
- do not join Kubernetes by default
- if reliable wired networking is added later, decide separately whether it is:
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
  `k8sRole = "server-worker"`
- `hosts/xev/` contains a buildable NixOS skeleton based on the live hardware
  scan from `192.168.1.13`
- the managed generation has been deployed
- the host joins k3s as a server-worker and enables Longhorn host prerequisites
- the normal deploy inventory includes `xev`
- a native Forgejo Actions runner is enabled on `xev` with the primary
  Docker-backed label policy from [ADR-0041](0041-native-forgejo-actions-runners.md)

Implemented for `xps`:

- `xps` is present in `inventory.nix` as `role = "laptop-workstation"` and
  `k8sRole = null`
- `hosts/xps/` contains a buildable NixOS workstation configuration
- the managed generation has been deployed
- temporary k3s participation was removed after the storage swap
- no Longhorn storage scheduling has been enabled for `xps`

`xps` should remain workstation-first until reliable wired networking and its
suspend, NVIDIA, Wi-Fi, and availability behavior are known.

## Follow-up Issues

- [#75](https://git.alc.xyz/alcxyz/nix-config/issues/75) Onboard `xev` as a
  stable k3s worker candidate. Completed 2026-05-14.
- [#76](https://git.alc.xyz/alcxyz/nix-config/issues/76) Prepare `xps` as a
  workstation host and decide its Kubernetes role separately. Completed
  2026-05-20 with `xps` kept outside k3s.

## Alternatives Considered

**Make `xev` a fourth k3s server-worker immediately** - rejected. A four-member
etcd cluster is not the desired failure-domain shape. `xev` becomes a server as
a replacement for `rpi0`, keeping the steady-state server count at three.

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

`xev` improves cluster workload, Forgejo Actions capacity, storage capacity, and
control-plane headroom while keeping a three-member etcd quorum.

The k8s role model needs a stable-agent role distinct from the current
ephemeral `agent` role.

The gitops repo remains the runtime source for Kubernetes workload placement,
but Nix owns host readiness: kernel, firewall, k3s, Longhorn prerequisites,
Netbird, and node labels.

`xps` remains useful as a NixOS workstation even if it never becomes a cluster
node.
