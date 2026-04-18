# ADR-0007: Custom packages in a separate repository with a filtered overlay

**Status:** Accepted
**Date:** 2026-04-18
**Applies to:** `flake.nix`

## Context

Several packages used in this config are not in nixpkgs: `zfs-auto-unlock`, `pihole-sync`, `ndrop`, `helium`, `t3code`, `claude-code`, `paperless-review`, `paperless-filetype-index`, `leantime-tidy`. These packages are also used outside this config (in other projects, as standalone tools, or in Docker-based workflows), making it natural to maintain them independently rather than embedding them in the config repo.

Importing an entire external overlay risks shadowing or conflicting with nixpkgs packages under the same names — a subtle and hard-to-debug failure mode.

## Decision

Custom packages live in a separate `nix-packages` flake (`github:alcxyz/nix-packages`). Rather than applying its overlay wholesale, only explicitly named packages are extracted into a local overlay:

```nix
overlays = [
  (final: prev: {
    ndrop                    = inputs.nix-packages.packages.${prev.system}.ndrop;
    zfs-auto-unlock          = inputs.nix-packages.packages.${prev.system}.zfs-auto-unlock;
    pihole-sync              = inputs.nix-packages.packages.${prev.system}.pihole-sync;
    claude-code              = inputs.nix-packages.packages.${prev.system}.claude-code;
    paperless-review         = inputs.nix-packages.packages.${prev.system}.paperless-review;
    # ... etc
  })
];
```

This makes custom packages available as `pkgs.<name>` throughout all modules, indistinguishable from nixpkgs packages in module code.

## Alternatives Considered

- **Inline `pkgs/` or `overlays/` directory in this repo** — Rejected. Package development and config management have different cadences; keeping them together conflates concerns and makes the config repo noisier. Packages used in other contexts would need to be duplicated.
- **Apply `inputs.nix-packages.overlays.default` wholesale** — Rejected. Exposes all packages from nix-packages into pkgs, risking silent shadowing of nixpkgs packages. The whitelist makes additions explicit and auditable.
- **fetchurl / builtins.fetchTarball per package** — Rejected. Loses flake-pinning benefits; no lock file tracking, no content-addressed fetching, harder to update.

## Consequences

- Custom package development is independent of this repo. nix-packages can be iterated and tested separately; this repo adopts updates by running `nix flake update nix-packages`.
- Adding a new custom package to the config requires changes in two repos: add the derivation to nix-packages, then add the name to the overlay whitelist in `flake.nix`, then update `flake.lock`.
- If a whitelisted package name does not exist in nix-packages for a given system, evaluation fails loudly at the overlay level.
- Do not use `inputs.nix-packages.overlays.default` — only the filtered individual extraction is intentional.
