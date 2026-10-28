# ADR-0007: Custom packages in a separate repository with a filtered overlay

**Status:** Accepted
**Date:** 2026-04-18
**Amended:** 2026-10-28
**History:** [replaced text](archive/0007-filtered-nix-packages-overlay-history.md)
**Applies to:** `flake/pkgs.nix`, `flake/core.nix`, `flake/per-system.nix`, `packages/`

## Context

Several packages used in this config are not in nixpkgs, for example
`zfs-auto-unlock`, `ndrop`, `zen-browser` and `nix-deploy`; nix-packages also
carries its own builds of `t3code` and `claude-code`, which nixpkgs now packages
too. These packages are also used outside this config (in other
projects, as standalone tools, or in Docker-based workflows), making it natural
to maintain them independently rather than embedding them in the config repo.

Importing an entire external overlay risks shadowing or conflicting with nixpkgs packages under the same names, a subtle and hard-to-debug failure mode.

## Decision

Custom packages live in the separate `nix-packages` flake, consumed from canonical Forgejo at `git+https://git.alc.xyz/alcxyz/nix-packages.git?ref=dev`. GitHub is a mirror. Rather than applying its overlay wholesale, only explicitly named packages are extracted into a local overlay. `flake/pkgs.nix` holds the current whitelist and builds the per-system package sets (`config.alc.pkgsFor`, wired in `flake/core.nix`) that every host, Home Manager configuration and check uses. The boundary looks like this:

```nix
(_final: _prev: let
  np = nix-packages.packages.${system};
  wanted = [
    "ndrop"
    "zfs-auto-unlock"
    "claude-code"
    # ... etc
  ];
in
  lib.filterAttrs (n: _: builtins.elem n wanted) np)
```

This makes custom packages available as `pkgs.<name>` throughout all modules, indistinguishable from nixpkgs packages in module code. Packages from other package flakes reach the same overlay by explicit name as well.

### Package ownership

`nix-gc-maintenance` is generic Unix tooling: its user, home directory,
profile roots, command paths, and remote target are supplied by arguments or
environment variables, and it contains no host inventory. Its executable and
contract test therefore belong in `nix-packages`; this repository selects the
external package and retains the NixOS, Darwin, package-set, and operator-command
configuration that consumes it.

`k8s-node-reboot` and its network-path audit are reusable operator tooling for
clusters that use the documented Longhorn and CloudNativePG safety contract.
Their executable sources and mocked safety tests belong together in
`nix-packages`. This repository retains the package selection, operator
commands, k3s service assembly, and ADR-0068 policy; moving identical helper
behavior does not replace runtime cluster qualification.

The remaining local package and patch ownership is intentional or needs
independent qualification:

| Source | Ownership |
|--------|-----------|
| `packages/nix-deploy` | Generates the consumer inventory and a thin wrapper under ADR-0009. The canonical executable, versioned runtime interface, and command tests live in `nix-packages`; this repository tests its generated inventory and wrapper precedence. |
| `packages/nixbox-*` | Remain with the branded boot and session configuration they implement. |
| DMS, RustFS, Wolf, and GStreamer patches under `modules/` | Remain with the module options, service assembly, and version-specific behavior they modify. |
| `packages/quickshell` | The polkit-details patch shared by DMS and the session splash; remains with those consumers. |
| Moonlight and Waynergy patches | Remain with their consumer overrides until each patched package has independent platform and input-path qualification. |
| `packages/ffmpeg-v4l2-request` and `packages/moonlight-rpi3` | Reusable extraction candidates after native ARM builds and target hardware decode/display qualification. |

ARM media extraction is tracked in [nix-packages #334](https://git.alc.xyz/alcxyz/nix-packages/issues/334).

## Alternatives Considered

- **Inline `pkgs/` or `overlays/` directory in this repo**: Rejected. Package development and config management have different cadences; keeping them together conflates concerns and makes the config repo noisier. Packages used in other contexts would need to be duplicated.
- **Apply `inputs.nix-packages.overlays.default` wholesale**: Rejected. Exposes all packages from nix-packages into pkgs, risking silent shadowing of nixpkgs packages. The whitelist makes additions explicit and auditable.
- **fetchurl / builtins.fetchTarball per package**: Rejected. Loses flake-pinning benefits; no lock file tracking, no content-addressed fetching, harder to update.

## Consequences

- Custom package development is independent of this repo. nix-packages can be iterated and tested separately; this repo adopts validated updates with `just lock-packages`, which moves the nix-packages lock to the `promoted` ref and leaves `flake.lock` to be reviewed and committed ([ADR-0080](0080-promoted-package-ref.md)).
- Adding a new custom package to the config requires changes in two repos: add the derivation to nix-packages, then add the name to the overlay whitelist in `flake/pkgs.nix`, then update and verify `flake.lock`.
- Required packages must exist on their supported systems. The overlay selects the intersection of its whitelist and the producer's exports; it does not itself assert a required package matrix. Platform and consumer checks ([ADR-0067](0067-explicit-consumer-and-platform-validation.md)) validate the actual selected packages and locked consumer and make required-package failures explicit; they do not turn the filtered overlay into a separate required-export validator.
- Package movement preserves the advertised platform set. Producer evaluation and native builds are followed by checks against the actual consumer lock before that lock is promoted. Runtime qualification remains explicit for cluster, display, hardware decode, and input behavior.
- Do not use `inputs.nix-packages.overlays.default`: only the filtered individual extraction is intentional.
