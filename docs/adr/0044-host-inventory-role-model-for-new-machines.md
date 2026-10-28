# ADR-0044: Host inventory role model for new machines

**Status:** Accepted, partially implemented (richer inventory dimensions remain); amended by ADR-0088
**Date:** 2026-05-11
**Amended:** 2026-10-09, 2026-10-28
**History:** [replaced text](archive/0044-host-inventory-role-model-for-new-machines-history.md)
**Applies to:** `inventory.nix`, `flake/hosts/`, `modules/nixos/`, `modules/home-manager/`, `hosts/`, `users/alc/`
**Amended by:** [ADR-0088](0088-tv-clients-share-one-appliance-profile.md) (the `embedded` role is now `tv-client`)

## Context

Three new machines were planned when this was decided:

- `xev` - to join the Kubernetes environment as a full-capability node
- `xps` - Dell XPS 15-inch laptop with an NVIDIA card; possible future
  Kubernetes node, with the role not decided
- a remotely managed laptop for family use, primarily for old Windows games
  through Heroic Launcher, with a separate non-operator user and isolated
  Netbird connectivity

The inventory then had four broad roles (`workstation`, `nuc`, `embedded` and
`mac`) and three Kubernetes roles: `agent` (labels the node
`workload-class=ephemeral`), `server-worker` and `server-control-plane`.

That was not expressive enough for the planned hosts. `xev` needs to be a stable
workload and storage-capable node without necessarily changing the embedded
etcd quorum. `xps` needs a laptop/workstation profile that can defer Kubernetes
membership. The family laptop needs remote management and gaming packages
without inheriting operator secrets, source workspaces, Kubernetes credentials,
or infrastructure administration tools.

## Decision

Make host intent explicit in the inventory role model before adding host
entries for new machines.

The inventory roles are `workstation`, `nuc`, `k8s-worker`,
`laptop-workstation`, `family-gaming`, `tv-client` (ADR-0088, formerly
`embedded`) and `mac`. The Kubernetes roles are `agent`, `stable-agent`,
`server-worker` and `server-control-plane`. They carry these role concepts:

1. **Stable Kubernetes worker.** A schedulable Linux node with
   `workload-class=stable`, Longhorn prerequisites, metrics access, and normal
   workload eligibility. This does not automatically imply k3s server or etcd
   membership: `stable-agent` is a schedulable agent labelled
   `workload-class=stable`, and the `k8s-worker` inventory role carries the
   server package sets without choosing a Kubernetes role.
2. **Laptop workstation.** A desktop-capable machine with laptop power,
   suspend, Wi-Fi, and GPU handling, but with Kubernetes membership optional
   (`laptop-workstation`).
3. **Family gaming client.** A non-operator desktop profile with Heroic
   Launcher, game runtime support, Netbird, OpenSSH for remote support, and no
   infra-admin workspace, Kubernetes credentials, operator keys, or private
   automation tokens (`family-gaming`; its package set avoids operator-heavy
   Kubernetes, cloud, AI, and infra administration packages).
4. **Remote support posture.** A separate inventory fact or role flag for hosts
   that are administered remotely but are not trusted infrastructure nodes.

`alc.host` exposes inventory role metadata and derived Kubernetes facts to
NixOS and Home Manager modules. The Linux Home Manager base and operator layers
are separate, so lower-trust Linux users avoid importing operator secrets and
Kubernetes credentials. Hosts can compose several users: `madsil` carries a
dedicated family user profile (`users/madsil/`) beside a minimal operator
profile.

The inventory should distinguish Kubernetes dimensions instead of overloading
one field:

- cluster membership: none, agent, server
- scheduling class: stable, ephemeral, control-plane-only
- storage eligibility: Longhorn storage, workload-only, excluded
- special taints or labels

The `k8sRole` field may remain for now, but new work should move toward a
richer typed representation under the `alc.host` module projection from
ADR-0043. Storage eligibility, support posture, and trust boundary are not yet
separate first-class inventory fields, and more modules can still move from
role-name branching to typed `alc.host` facts.

Do not add a host to `inventory.nix` until it has at least a minimal buildable
configuration path. Placeholder inventory entries that point to missing files
would make flake evaluation fragile.

## Alternatives Considered

**Reuse `nuc` and `agent` for all new Linux machines** - rejected. `xev`, `xps`,
and the family laptop have different trust, workload, storage, and user
profiles. Reusing existing roles would hide important differences.

**Make every capable Linux machine a k3s server-worker** - rejected. The
embedded etcd topology already had three server members. Adding a fourth
server changes quorum characteristics without a clear control-plane decision.
Stable workload participation and etcd membership should be separate.

**Add host entries immediately with TODO hardware configs** - rejected. It would
make ordinary flake checks and host enumeration fail or depend on incomplete
files. Host entries should land with buildable skeletons.

## Consequences

New-machine onboarding starts with role semantics, not copied host files.

`xev`, `xps` and the family laptop (`madsil`) are in the inventory as
`k8s-worker`, `laptop-workstation` and `family-gaming` hosts, each with a
buildable host configuration. Their Kubernetes membership is decided per host
([ADR-0045](0045-xev-and-xps-kubernetes-node-onboarding.md)), not by the
inventory role.

`xev` is a real cluster resource without an accidental change to etcd quorum:
its `server-worker` membership is ADR-0045's deliberate decision, not a side
effect of its inventory role.

`xps` is a laptop workstation without Kubernetes membership (ADR-0045).

The family laptop can be managed declaratively without leaking operator
credentials or infrastructure access into a lower-trust machine; the gaps that
remain on madsil, including SSH agent forwarding, are recorded in
[ADR-0046](0046-remotely-managed-family-gaming-laptop.md).

Future modules should prefer explicit typed host facts over host-name checks.
