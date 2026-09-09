# ADR-0007: Custom packages in a separate repository with a filtered overlay

**Status:** Accepted
**Date:** 2026-04-18
**Applies to:** `flake/pkgs.nix`, `flake/per-system.nix`

## Context

Several packages used in this config are not in nixpkgs: `zfs-auto-unlock`, `ndrop`, `helium`, `t3code`, `claude-code`, `paperless-review`, `paperless-filetype-index`, `leantime-tidy`. These packages are also used outside this config (in other projects, as standalone tools, or in Docker-based workflows), making it natural to maintain them independently rather than embedding them in the config repo.

Importing an entire external overlay risks shadowing or conflicting with nixpkgs packages under the same names — a subtle and hard-to-debug failure mode.

## Decision

Custom packages live in the separate `nix-packages` flake, consumed from canonical Forgejo at `git+https://git.alc.xyz/alcxyz/nix-packages.git?ref=dev`. GitHub is a mirror. Rather than applying its overlay wholesale, only explicitly named packages are extracted into a local overlay. The following illustrates that boundary; the current whitelist is implemented in `flake/pkgs.nix`:

```nix
overlays = [
  (final: prev: {
    ndrop                    = inputs.nix-packages.packages.${prev.system}.ndrop;
    zfs-auto-unlock          = inputs.nix-packages.packages.${prev.system}.zfs-auto-unlock;
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
- Adding a new custom package to the config requires changes in two repos: add the derivation to nix-packages, then add the name to the overlay whitelist in `flake/pkgs.nix`, then update and verify `flake.lock`.
- Required packages must exist on their supported systems. The current overlay selects the intersection of its whitelist and the producer's exports; it does not itself assert a required package matrix. Platform and consumer checks must make required-package failures explicit.
- Do not use `inputs.nix-packages.overlays.default` — only the filtered individual extraction is intentional.

## September 2026 follow-through

The audit found duplicate deployment implementations and reusable package code
outside the intended package boundary. Implementation remains tracked in
Forgejo:

- [Consolidate the generic deployment implementation](https://git.alc.xyz/alcxyz/nix-packages/issues/322)
- [Restore reusable package ownership](https://git.alc.xyz/alcxyz/nix-packages/issues/323)
- [Validate candidate packages in the consumer context](https://git.alc.xyz/alcxyz/nix-config/issues/275)

[ADR-0067](0067-explicit-consumer-and-platform-validation.md) defines explicit
platform and consumer checks. Those checks validate the actual selected packages
and locked consumer; they do not turn the filtered overlay into a separate
required-export validator.

### Package ownership inventory

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
| DMS, Quickshell, RustFS, Wolf, and GStreamer patches under `modules/` | Remain with the module options, service assembly, and version-specific behavior they modify. |
| Hyprland, Moonlight, and Waynergy patches | Remain with their consumer overrides until each patched package has independent platform and input-path qualification. |
| `packages/ffmpeg-v4l2-request` and `packages/moonlight-rpi3` | Reusable extraction candidates after native ARM builds and target hardware decode/display qualification. |

ARM media extraction is tracked in [nix-packages #334](https://git.alc.xyz/alcxyz/nix-packages/issues/334).

Package movement preserves the advertised platform set. Producer evaluation and
native builds are followed by checks against the actual consumer lock before
that lock is promoted. Runtime qualification remains explicit for cluster,
display, hardware decode, and input behavior.
