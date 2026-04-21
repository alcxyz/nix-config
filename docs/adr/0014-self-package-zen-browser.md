# ADR-0014: Self-package Zen Browser instead of using a third-party flake

**Status:** Accepted
**Date:** 2026-04-21
**Applies to:** `flake.nix`, `modules/nixos/common/pkgsets.nix`, `alcxyz/nix-packages`

## Context

Zen Browser was consumed via `github:youwen5/zen-browser-flake`, a third-party flake maintained by an individual outside our control. This flake has full access to produce arbitrary build outputs that run on our machines. Zen Browser is not yet in nixpkgs, so a direct nixpkgs reference is not an option.

The third-party flake is essentially a thin wrapper: it fetches a prebuilt tarball from Zen's official GitHub releases, patches ELF binaries with `autoPatchelfHook`, and wraps via nixpkgs' `wrapFirefox`. There is no complex build-from-source logic that would justify delegating to an external maintainer.

Per [ADR-0007](0007-filtered-nix-packages-overlay.md), custom packages belong in `alcxyz/nix-packages` and are consumed via a filtered overlay.

## Decision

Package Zen Browser directly in `alcxyz/nix-packages`, fetching the official release tarball from `github:zen-browser/desktop`. The derivation uses `autoPatchelfHook` + `patchelfUnstable` (with `--no-clobber-old-sections` for Mozilla ELF quirks) and `wrapFirefox` for desktop integration. An automated CI job checks for new releases daily and opens update PRs.

The `youwen5/zen-browser-flake` input is removed from `nix-config/flake.nix`. Zen Browser is added to the filtered overlay whitelist and referenced as `pkgs.zen-browser` in `pkgsets.nix`, consistent with all other custom packages.

## Alternatives Considered

- **Keep the third-party flake** — Rejected. Unnecessary trust in a single external maintainer for a package that is straightforward to build ourselves. Every flake input is a supply-chain dependency.
- **Fork the third-party flake** — Rejected. Forking still requires ongoing merge reviews. Packaging from scratch in our own repo is equally simple and avoids carrying upstream's structure and update tooling.
- **Wait for Zen to land in nixpkgs** — Rejected. No timeline for upstream inclusion. Self-packaging is low-effort and can be dropped if/when nixpkgs adopts it.

## Consequences

- The trust surface for Zen Browser is reduced to: Zen's own official GitHub releases + our own derivation code. No third-party Nix code in the chain.
- Updates are automated via the same CI pattern as other nix-packages (daily cron, PR per version bump).
- Currently Linux x86_64 only. macOS support can be added later as a separate effort.
- If Zen Browser lands in nixpkgs in the future, the custom package can be removed and the overlay entry dropped — standard deprecation path per ADR-0007.
