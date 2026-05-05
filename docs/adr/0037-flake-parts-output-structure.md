# ADR-0037: Flake output structure via flake-parts

**Status:** Accepted
**Date:** 2026-05-05
**Applies to:** `flake.nix`, `flake/`

## Context

`flake.nix` had grown into a mixed entrypoint for several concerns:

- flake inputs and top-level identity values
- per-system package imports and overlays
- NixOS and Darwin host construction
- Home Manager configuration construction
- development shells and package exports

This made unrelated changes collide in one large file. The host inventory work
also made the split clearer: host facts now belong in `inventory.nix`, while the
flake should focus on wiring those facts into exported flake outputs.

## Decision

Use `flake-parts` as the flake output framework.

`flake.nix` remains the entrypoint for inputs, stable shared values, and the
`flake-parts.lib.mkFlake` call. Implementation details move into focused files
under `flake/`:

- `flake/pkgs.nix` builds `pkgsFor` for each supported system and owns overlays
- `flake/hosts.nix` builds NixOS, Darwin, and Home Manager configurations from
  `inventory.nix`
- `flake/per-system.nix` owns per-system exports such as dev shells and packages

`inventory.nix` remains the single source of truth for host metadata. `flake-parts`
does not replace inventory; it gives the flake a standard structure for exporting
the inventory-derived outputs.

## Alternatives Considered

**Keep a monolithic `flake.nix`** - rejected. It works, but it keeps unrelated
output wiring in one file and makes future host and package changes noisier than
necessary.

**Create a custom local flake module convention** - rejected. A repo-specific
loader could work, but it would be less intuitive than using an established
Nix flake composition library.

**Move host metadata into flake-parts modules** - rejected. Host facts are
operator inventory, not flake framework configuration. Keeping them in
`inventory.nix` preserves the source-of-truth model from ADR-0036.

## Consequences

Top-level `flake.nix` is smaller and mostly declarative.

Future per-system outputs should be added in `flake/per-system.nix`.

Future host output changes should be made in `flake/hosts.nix`, with host facts
still added or changed in `inventory.nix`.

`flake-parts` becomes part of the lockfile and must be kept current with normal
flake input updates.
