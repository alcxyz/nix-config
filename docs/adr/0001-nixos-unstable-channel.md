# ADR-0001: Use nixos-unstable as the primary nixpkgs channel

**Status:** Accepted
**Date:** 2026-04-18
**Amended:** 2026-11-09
**History:** [replaced text](archive/0001-nixos-unstable-channel-history.md)
**Applies to:** `flake.nix`, `flake/pkgs.nix`, `flake/pins.nix`

## Context

The desktop Wayland ecosystem and fast-moving applications require recent
packages. The fleet uses nixos-unstable as its primary package set, with
explicit exceptions where compatibility requires a different dependency graph.

## Decision

Use `github:NixOS/nixpkgs/nixos-unstable` as the primary `nixpkgs` input.
Inputs that are intended to share this package set declare
`inputs.<name>.inputs.nixpkgs.follows = "nixpkgs"`. Preserve those follows
unless a reviewed compatibility exception requires changing them.

This is not a claim that every input shares one evaluated package set.
`flake.nix` retains independent pinned `nixpkgs-openbao`,
`nixpkgs-azure-cli` and `nixpkgs-previous` inputs. The package pins in
`flake/pins.nix` ([ADR-0110](0110-package-pins-in-one-table.md)) take OpenBao
from the first, Azure CLI, Khal and Calibre from the second, and packages a
flake update broke from the third. `flake/pkgs.nix` also builds the
request-enabled FFmpeg dependency set and the Pi 3 Moonlight package from
`nixpkgs-azure-cli`. Other application flakes may retain their own dependency
pins when they do not follow the primary input. These are selected-package
exceptions, not a stable base for the fleet.

Both nix-packages nixpkgs inputs follow the host package set. The managed AI
stack updater instead overrides both with the running system's registry
source, as [ADR-0104](0104-ai-stack-on-system-nixpkgs.md) specifies. That contract
does not remove the independent selected-package exceptions above.

## Alternatives Considered

- **A versioned stable primary channel:** rejected because the fast-moving
  Hyprland, Quickshell and browser packages need newer dependencies.
- **nixos-unstable-small:** offers no useful benefit for this desktop-heavy
  configuration and does not cover all required packages.
- **A stable base with an unstable overlay:** adds evaluation complexity and
  ABI compatibility risks. Narrow compatibility pins remain explicit instead.

## Consequences

Update the primary lock periodically for security and package fixes. Regressions
may require temporary package pins, which go in `flake/pins.nix` (ADR-0110);
review those exceptions when updating them.
Follows reduce duplicated package sets where used, but independent inputs and
compatibility pins can still add separate closures and require consumer checks.
