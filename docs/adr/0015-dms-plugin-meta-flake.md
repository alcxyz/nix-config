# ADR-0015: DMS plugin meta-flake

**Status:** Accepted
**Date:** 2026-04-23
**Applies to:** `flake.nix`, `modules/home-manager/services/dms/default.nix`

## Context

Each DMS plugin was declared as a separate `flake = false` input in the main nix-config flake. With six plugins (and growing), this created clutter in `flake.nix` and required updating each input individually when bumping plugin versions.

## Decision

Introduce a dedicated `dms-plugins` meta-flake (`github:alcxyz/dms-plugins`) that aggregates all plugin sources as inputs and re-exports them via `srcs`. The main nix-config references this single flake and accesses individual plugins through `inputs.dms-plugins.srcs.<name>`.

## Alternatives Considered

- **Keep individual inputs.** Simple and allows independent pinning per plugin, but scales poorly as the plugin count grows and adds noise to flake.nix.
- **Use the dms-plugin-registry as the bundle.** The registry is an upstream community project (AvengeMedia) meant for discovery, not personal dependency management. Coupling nix-config to it would mix concerns.

## Consequences

- One `nix flake update dms-plugins` in nix-config pulls whatever the meta-flake has pinned.
- Adding a new plugin means updating two places: the meta-flake and the DMS module.
- Individual plugin pinning is still possible via `inputs.dms-plugins.inputs.<name>.url` overrides.
- Plugin version bumps require a commit to `dms-plugins` first, then updating nix-config — an extra step compared to direct inputs, traded for cleaner organisation.
