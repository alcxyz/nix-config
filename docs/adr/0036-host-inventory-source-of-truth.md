# ADR-0036: Host inventory as source of truth

**Status:** Accepted
**Date:** 2026-05-05
**Applies to:** `inventory.nix`, `flake.nix`, package roles, workspace roles, k3s roles

## Context

Host facts are currently spread across multiple files:

- `flake.nix` declares host architecture, platform, config path, and icon
- Home Manager host files select package role presets from `pkgsets.nix`
- NixOS host files select k3s role details such as `server` or `agent`
- the desired `~/src` workspace layout needs host-specific repo profiles

These are all expressions of the same underlying host intent. Keeping them
independent makes drift likely: a host can be a NUC in package selection, an
ordinary server in flake wiring, and a different kind of k3s node in its host
config.

## Decision

Introduce `inventory.nix` as the canonical host inventory.

The inventory owns stable host facts:

- `system` — Nix build/evaluation system, such as `x86_64-linux`
- `platform` — `nixos` or `darwin`
- `role` — machine class, such as `workstation`, `nuc`, `embedded`, or `mac`
- `k8sRole` — semantic cluster role, or `null` when not a node
- `configuration` — host configuration path
- `osIcon` — prompt/UI icon metadata

The inventory also defines role metadata:

- `homePackageSet`
- `systemPackageSet`
- `workspaceProfile`

`pkgsets.nix` remains the package catalog. It still defines what each package
set contains, but host files should no longer independently decide which package
set represents a host.

k3s roles are semantic inventory values:

- `agent` — k3s agent only
- `server-worker` — k3s server that can run normal workloads
- `server-control-plane` — k3s server kept unschedulable for normal workloads

The k3s module translates those semantic roles into implementation details and
asserts that explicit host overrides do not contradict inventory intent.

## Tracking Issues

1. [#27](https://git.alc.xyz/alcxyz/nix-config/issues/27) Introduce host inventory as source of truth.
2. [#28](https://git.alc.xyz/alcxyz/nix-config/issues/28) Derive package roles and flake host metadata from inventory.
3. [#29](https://git.alc.xyz/alcxyz/nix-config/issues/29) Derive workspace profiles from host inventory.
4. [#30](https://git.alc.xyz/alcxyz/nix-config/issues/30) Derive k3s node intent from host inventory.

## Alternatives Considered

**Keep role choices in host files** — rejected. It keeps each file simple, but
requires humans to remember that architecture, package role, workspace profile,
and cluster role must be updated together.

**Put workspace profiles directly in `pkgsets.nix`** — rejected. Packages and
source checkouts are related through host intent, but they are different
concerns. Mixing them would make the package catalog responsible for too much.

**Infer everything from host names** — rejected. Names like `nux`, `nex`, `xyz`,
and future `xev` are meaningful to the operator, but policy should be explicit.

## Consequences

Adding a host starts in `inventory.nix`. Consumers derive host metadata from
there instead of carrying their own parallel host maps.

Package role drift is reduced because Home Manager and NixOS package layers use
the role metadata from inventory.

The future workspace module can select `~/src` checkout profiles from the same
role metadata instead of introducing a separate host classification.

k3s role intent becomes visible without reading each host's service flags.
