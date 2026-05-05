# ADR-0034: Add nex as the third k3s server

**Status:** Accepted
**Date:** 2026-05-05
**Applies to:** `hosts/nex`, `flake.nix`, k3s cluster, nix-secrets, gitops storage

## Context

ADR-0017 defines the intended k3s topology after the second NUC joins the
cluster: three k3s server nodes for embedded-etcd quorum, with normal workloads
running on the NUC-class machines and `rpi0` kept tainted for control-plane
resilience.

The second NUC now needs a concrete host identity before the NixOS and secrets
work can start. The name `xev` is reserved for a later Ryzen 1700X machine, so
the second NUC should not consume that name.

The current cluster shape is:

| Host | Role | Scheduling intent |
|------|------|-------------------|
| `nux` | k3s server + worker | primary stable workload host |
| `rpi0` | k3s server | tainted `NoSchedule` control-plane support |
| `xyz` | k3s agent | opportunistic workstation capacity |

The missing piece is the third stable k3s server that turns the embedded-etcd
control plane into a one-node-failure-tolerant quorum.

## Decision

Name the second NUC `nex`.

`nex` will be managed by `nix-config` as an `x86_64-linux` NixOS server host and
will join the existing k3s cluster as a `server + worker` node. It should use the
existing k3s server token from `nix-secrets/cluster-bootstrap/secrets.yaml` and
join through the current API endpoint on `nux`:

```nix
k3s = {
  enable = true;
  role = "server";
  serverAddr = "https://192.168.1.15:6443";
  tokenFile = config.sops.secrets.k3s_server_token.path;
};
```

Do not apply the `rpi0` control-plane `NoSchedule` taint to `nex`; the purpose
of the host is both quorum and stable workload capacity. If rollout risk requires
a slower start, use a temporary taint during bootstrap and remove it after node,
storage, and workload validation.

`xev` remains reserved for the later Ryzen 1700X machine and should be treated
as a separate future host with its own role decision.

## Rollout Issues

Track the work as separate issues so hardware, secrets, NixOS, cluster join, and
post-join workload changes can move independently:

1. [#19](https://git.alc.xyz/alcxyz/nix-config/issues/19) Prepare `nex` network identity and install inputs.
2. [#20](https://git.alc.xyz/alcxyz/nix-config/issues/20) Add declarative `nex` host scaffolding to `nix-config`.
3. [#21](https://git.alc.xyz/alcxyz/nix-config/issues/21) Add `nex` host secrets and distributed-build credentials to `nix-secrets`.
4. [#22](https://git.alc.xyz/alcxyz/nix-config/issues/22) Install NixOS on `nex` and deploy the first managed generation.
5. [#23](https://git.alc.xyz/alcxyz/nix-config/issues/23) Join `nex` to k3s as the third server + worker and validate quorum.
6. [#24](https://git.alc.xyz/alcxyz/nix-config/issues/24) Rebalance storage and stateful workloads after `nex` is healthy.

## Alternatives Considered

**Name the second NUC `xev`** — rejected because `xev` is reserved for the later
Ryzen 1700X machine.

**Add `nex` as a worker-only node** — rejected for the same reason ADR-0017
rejected worker-only NUC #2: the cluster needs a third stable server to reach the
intended embedded-etcd quorum shape.

**Keep the second NUC outside k3s initially** — rejected as the default plan
because the cluster already has a documented need for the third server. It is
acceptable only as a short hardware burn-in step before applying the managed k3s
configuration.

**Make `nex` a tainted control-plane-only node** — rejected because NUC-class
hardware should carry normal workloads. `rpi0` already covers the small,
tainted-control-plane role.

## Consequences

Adding `nex` completes the intended three-server k3s control plane and allows
the cluster to tolerate one server-node failure without losing etcd quorum.

Host onboarding now has several prerequisites that must happen in order:

- reserve LAN identity before writing host-specific config
- generate or import host SSH keys before final SOPS recipient updates
- add a dedicated build key before relying on `xyz` for distributed builds
- take or verify etcd snapshots before adding the third server
- validate node health and workload scheduling before rebalancing stateful apps

Stateful workload placement can be improved after `nex` joins, but should be
handled as a separate post-join step rather than mixed into first boot.
