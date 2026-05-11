# ADR-0044: Host inventory role model for new machines

**Status:** Accepted (partially implemented 2026-05-12)
**Date:** 2026-05-11
**Applies to:** `inventory.nix`, `flake/hosts/`, `modules/nixos/`, `modules/home-manager/`, `hosts/`, `users/alc/`

## Context

Three new machines are planned:

- `xev` - intended to join the Kubernetes environment as a full-capability
  node
- `xps` - Dell XPS 15-inch laptop with an NVIDIA card; possible future
  Kubernetes node, but the role is not decided
- a remotely managed laptop for family use, primarily for old Windows games
  through Heroic Launcher, with a separate non-operator user and isolated
  Netbird connectivity

The current inventory has four broad roles:

- `workstation`
- `nuc`
- `embedded`
- `mac`

The current Kubernetes role model has:

- `agent` - currently labels the node as `workload-class=ephemeral`
- `server-worker`
- `server-control-plane`

That is not expressive enough for the planned hosts. `xev` needs to be a stable
workload and storage-capable node without necessarily changing the embedded
etcd quorum. `xps` needs a laptop/workstation profile that can defer Kubernetes
membership. The family laptop needs remote management and gaming packages
without inheriting operator secrets, source workspaces, Kubernetes credentials,
or infrastructure administration tools.

## Decision

Before adding host entries for the new machines, extend the inventory role
model so host intent is explicit.

Add or prepare role concepts for:

1. **Stable Kubernetes worker.** A schedulable Linux node with
   `workload-class=stable`, Longhorn prerequisites, metrics access, and normal
   workload eligibility. This should not automatically imply k3s server or etcd
   membership.
2. **Laptop workstation.** A desktop-capable machine with laptop power,
   suspend, Wi-Fi, and GPU handling, but with Kubernetes membership optional.
3. **Family gaming client.** A non-operator desktop profile with Heroic
   Launcher, game runtime support, Netbird, OpenSSH for remote support, and no
   infra-admin workspace, Kubernetes credentials, operator keys, or private
   automation tokens.
4. **Remote support posture.** A separate inventory fact or role flag for hosts
   that are administered remotely but are not trusted infrastructure nodes.

The inventory should distinguish Kubernetes dimensions instead of overloading
one field:

- cluster membership: none, agent, server
- scheduling class: stable, ephemeral, control-plane-only
- storage eligibility: Longhorn storage, workload-only, excluded
- special taints or labels

The current `k8sRole` field may remain temporarily, but new work should move
toward a richer typed representation under the planned `alc.host` module
projection from ADR-0043.

Do not add the new hosts to `inventory.nix` until each host has at least a
minimal buildable configuration path. Placeholder inventory entries that point
to missing files would make flake evaluation fragile.

## Implementation Status

Implemented:

- inventory role vocabulary now includes `k8s-worker`, `laptop-workstation`,
  and `family-gaming`
- Kubernetes role vocabulary now includes `stable-agent`
- `alc.host` exposes inventory role metadata and derived Kubernetes facts to
  NixOS and Home Manager modules
- the `family-gaming` package set avoids operator-heavy Kubernetes, cloud, AI,
  and infra administration packages

Still pending:

- richer inventory dimensions for storage eligibility, support posture, and
  trust boundary; these are not yet separate first-class fields
- buildable host skeletons for `xev`, `xps`, and the family laptop
- a dedicated family user profile and multi-user host composition
- migration of more modules from role-name branching to typed `alc.host` facts

## Alternatives Considered

**Reuse `nuc` and `agent` for all new Linux machines** - rejected. `xev`, `xps`,
and the family laptop have different trust, workload, storage, and user
profiles. Reusing existing roles would hide important differences.

**Make every capable Linux machine a k3s server-worker** - rejected. The
current embedded etcd topology already has three server members. Adding a
fourth server changes quorum characteristics without a clear control-plane
decision. Stable workload participation and etcd membership should be separate.

**Add host entries immediately with TODO hardware configs** - rejected. It would
make ordinary flake checks and host enumeration fail or depend on incomplete
files. Host entries should land with buildable skeletons.

## Consequences

New-machine onboarding starts with role semantics, not copied host files.

`xev` can become a real cluster resource without accidentally changing etcd
quorum.

`xps` can be prepared as a laptop workstation while deferring Kubernetes
membership.

The family laptop can be managed declaratively without leaking operator
credentials or infrastructure access into a lower-trust machine.

Future modules should prefer explicit typed host facts over host-name checks.
