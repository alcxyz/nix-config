# ADR-0001: Use nixos-unstable as the primary nixpkgs channel

**Status:** Accepted
**Date:** 2026-04-18
**Applies to:** `flake.nix`

## Context

Nix offers several release channels: `nixos-unstable`, versioned stable releases (e.g. `nixos-24.11`), and `nixos-unstable-small`. This repo drives a desktop workstation (xyz) running Hyprland on Wayland, alongside servers and a macOS host. Several inputs — Hyprland, hyprland-plugins, quickshell, zen-browser — are fast-moving projects that track nixpkgs-unstable directly and frequently require packages unavailable or outdated on stable channels.

Because all flake inputs are pinned via `inputs.<name>.inputs.nixpkgs.follows = "nixpkgs"`, this single channel decision propagates consistently to every dependency.

## Decision

Use `github:NixOS/nixpkgs/nixos-unstable` as the single `nixpkgs` input. All flake inputs that accept a nixpkgs override are pinned to follow it:

```nix
inputs.<name>.inputs.nixpkgs.follows = "nixpkgs";
```

## Alternatives Considered

- **nixos-stable (versioned release)** — Rejected. Hyprland, quickshell, and zen-browser regularly require recent nixpkgs; stable channel lags too far behind and would require significant patching or per-package overrides.
- **nixos-unstable-small** — Rejected. Smaller package set; not all required packages are available and it offers no meaningful benefit for a desktop-heavy workstation config.
- **Mixed channels (stable base + unstable overlay)** — Rejected. Significantly increases evaluation complexity and risks subtle ABI mismatches between packages from different channels.

## Consequences

- Agents and contributors must not switch this to a stable channel or remove `follows` overrides — doing so breaks the Hyprland/Wayland ecosystem inputs and introduces version inconsistencies across the dependency graph.
- `flake.lock` must be updated periodically to pick up security fixes and package updates; occasional nixpkgs-unstable regressions may require temporarily pinning individual packages.
- All inputs share one evaluated nixpkgs, keeping the store closure consistent and avoiding duplicate package sets.
