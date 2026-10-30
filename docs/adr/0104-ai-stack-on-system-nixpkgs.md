# ADR-0104: Build nix-packages for the hosts with the hosts' own nixpkgs

**Status:** Accepted
**Date:** 2026-10-30
**Applies to:** `flake.nix` (`nix-packages` input), `modules/home-manager/services/t3code/` (`t3code-auto-update`); amends [ADR-0077](0077-ai-stack-profile-outside-home-manager.md)

## Context

nix-packages has two nixpkgs inputs: `nixpkgs` (`nixos-25.05`) and
`nixpkgs-unstable`, which T3 Code, herdr and forgejo-runner-cancellation build
on. nix-config made only the first follow its own nixpkgs, and the AI stack
profile (ADR-0077) was built from nix-packages' `promoted` ref with
nix-packages' own lock. That lock only moves by hand, and on 2026-10-30
`nixpkgs-unstable` was still the 2026-07-08 revision.

ADR-0077 accepted this because nothing in the bundle loaded system graphics
drivers. Since nix-config #902 the T3 Code desktop app is launched from the
profile, and it does: built against glibc 2.42, its GPU process could not load
xyz's graphics driver, which needs `GLIBC_2.43`, and the app rendered in
software (nix-config #901). A one-off bump of nix-packages' lock fixed it
(nix-packages #701); without a structural fix the next drift repeats it
(nix-config #904).

## Decision

What nix-packages delivers to a host is built with that host's nixpkgs, not
with nix-packages' own lock.

- nix-config consumes nix-packages with **both** nixpkgs inputs following its
  own `nixpkgs`. Packages in home profiles, the profile's seed bundle and the
  promoter's consumer verification and configuration gate (ADR-0080) all use
  the nixpkgs the hosts deploy.
- `t3code-auto-update` builds the bundle with nix-packages' `nixpkgs` and
  `nixpkgs-unstable` overridden by the **running system's** nixpkgs, which
  NixOS records in the system flake registry (`/etc/nix/registry.json`, id
  `nixpkgs`, a store path). A host without that entry refuses the update with
  exit 76, which systemd does not retry before the next timer run, instead of
  building against another nixpkgs.
- Owned flakes' own locks (nix-packages, pandora, nix-secrets and the other
  owned inputs) get no scheduled bump. Every owned input nix-config consumes
  follows its `nixpkgs`, except the `bivrost` and `work` inputs, which follow
  the deliberately pinned `nixpkgs-azure-cli`. So their own locks only govern
  their standalone CI and dev shells, and move by hand when those need it.

## Alternatives Considered

- **Build the bundle against nix-config's locked nixpkgs**: a nixpkgs bump on
  `dev` is ahead of what a host runs until that host is deployed, and the
  driver comes from the running system.
- **Look up the system's nixpkgs revision and fetch it** (`nixos-version
  --json`): needs a network fetch of nixpkgs, while the registry already names
  the exact local source.
- **Bump the owned flakes' locks in step with nix-config on a schedule**:
  limits drift to one cycle instead of removing it, and adds a job and a bump
  PR per repository.
- **Independent scheduled `nix flake update` in each repository**: simpler,
  but leaves the repositories on different nixpkgs between runs.
- **Keep manual bumps and alert on stale locks**: still lets a drifted lock
  reach a host.

## Consequences

The bundle's glibc and libraries match the system's after each updater run.
A NixOS switch to a new nixpkgs makes the next run (hourly on xyz) build a new
bundle even when `promoted` has not moved, and switch to it through the usual
idle and downgrade guards. Until then the profile still holds the bundle built
for the previous system.

nix-packages' packages must build with both its own lock (its CI and the
promoter's standalone verification) and the hosts' nixpkgs (nix-config's
checks, the promoter's consumer verification and the updater). A nix-config
nixpkgs bump that breaks one fails nix-config's checks, and the fix lands in
nix-packages, as nix-packages #701 adapted T3 Code to nixpkgs splitting
`t3code` into `t3code.unwrapped` and a wrapper. A promoted revision that
builds with nix-config's lock but not with an older running system makes the
updater fail until that host is deployed.

The updater builds against nixpkgs revisions nix-packages' CI did not use, so
its T3 Code builds are local; when nix-config's lock matches the system, the
promoter's consumer verification has already built the same derivations.
nix-packages' own `nixpkgs-unstable` and `nixpkgs` locks no longer reach any
host. The updater therefore needs a NixOS host built from the flake; the macOS
host does not use the profile and installs T3 Code as a Homebrew cask
(ADR-0077).
