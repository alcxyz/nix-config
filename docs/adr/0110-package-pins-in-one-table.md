# ADR-0110: Keep package pins in one table

**Status:** Accepted
**Date:** 2026-11-09
**Applies to:** `flake/pins.nix`, `flake/overlays/pins.nix`, `flake/pkgs.nix`,
the `nixpkgs-previous` input in `flake.nix`, `flake/checks/package-pins.nix`

## Context

The fleet shares one `nixpkgs` lock ([ADR-0001](0001-nixos-unstable-channel.md)),
so a package that a flake update removes or breaks blocks every host that
installs it, and the update with it. On 2026-11-08 nixpkgs' temporary removal
of `brave` and `brave-origin` (removed 2026-11-03, re-added 2026-11-07, not
yet in `nixos-unstable`) stopped xyz's Home Manager and xps from evaluating.
The nix-packages promoter, which validates against nix-config `dev`, failed
for the same reason. Rolling the lock back would also roll back every host
that had already switched.

Earlier pins (OpenBao, Azure CLI, Khal, Calibre) were inline `inherit` lines
in the `flake/pkgs.nix` overlay, each with its own comment, so there was no
one place to see what is pinned, why, or when a pin can go.

## Decision

Package pins live in `flake/pins.nix`, one entry per top-level package
attribute:

- `input` names the flake input that provides the package, and `reason` says
  why it is pinned and what ends the pin. Both are required.
- `whileBroken = true` applies the pin only while the primary package fails
  to evaluate (removed, marked broken or throwing). Once nixpkgs evaluates it
  again, the primary package is used and evaluation warns that the entry can
  be removed. Without it, the pin applies until the entry is removed, which
  is what a package that evaluates but fails to build or run needs.

`flake/overlays/pins.nix` applies the table as the last overlay in
`flake/pkgs.nix`, so a pin wins over the other overlays, for every host and
system. It rejects an entry with an unknown field, no reason, or an input that
`flake.nix` does not declare.

`nixpkgs-previous` is the input for pins against a regressing flake update:
it points at the nixpkgs revision where the pinned packages last built,
usually the one the fleet ran before the update. Moving it moves every pin
that names it, so check those first. OpenBao and Azure CLI, Khal and Calibre
keep their own inputs (`nixpkgs-openbao`, `nixpkgs-azure-cli`).

To pin a package a flake update broke: point `nixpkgs-previous` at a revision
where it builds, run `nix flake lock`, add an entry and deploy. Remove the
entry once nixpkgs works again.

`brave` and `brave-origin` are pinned to `nixpkgs-previous` at
`1d060086` (2026-11-03, the revision the fleet ran before the update) with
`whileBroken = true`.

The `package-pins-contract` flake check covers the overlay on synthetic
package sets: a `whileBroken` pin applies while the primary throws and yields
it once it evaluates, a plain pin always applies, and the three invalid
entries fail.

## Alternatives Considered

- **Roll the whole lock back:** rejected because it rolls back every host that
  already switched, for a problem in two packages.
- **Package Brave in nix-packages:** rejected for a removal that upstream had
  already reverted; it would duplicate nixpkgs' packaging for days.
- **Keep inline `inherit` lines in `flake/pkgs.nix`:** rejected because the
  pins, their reasons and their end conditions were scattered, and a pin for a
  removal had to be noticed and removed by hand.
- **One input per pin:** still possible where a pin needs its own revision, as
  OpenBao does; a shared `nixpkgs-previous` covers the common case of
  "what built before this update" without a new input each time.

## Consequences

- A broken package no longer blocks a flake update: pin it, and the rest of
  the fleet moves on. A `whileBroken` pin ends by itself when nixpkgs is
  fixed, and the warning says when to delete it.
- A pinned package brings its own dependency closure from the pinned
  revision, which adds store paths and holds back its security fixes. Keep
  pins short-lived and review them when updating the lock.
- `whileBroken` evaluates the primary package to decide, so an evaluation
  error there is caught only when it is a `throw` (removed or broken
  packages); an `abort` still fails evaluation.
- Pins cover top-level package attributes only, not nested sets such as
  `python3Packages`.
- A pin takes the package from its input's `legacyPackages`, which uses
  nixpkgs' default configuration, not the fleet's (`allowUnfree`,
  `permittedInsecurePackages`). An unfree or insecure package therefore
  fails to evaluate from a pin; `brave` and `brave-origin` are MPL-2.0.
- The `package-pins-contract` check passes the overlay a silent warn
  function, so only real pins print the removal warning.
