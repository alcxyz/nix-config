# ADR-0089: Released and dev app inputs

**Status:** Accepted
**Date:** 2026-10-10
**Applies to:** `flake.nix`, `flake/pkgs.nix`, `scripts/update-inputs/update-apps.sh`, `scripts/update-inputs/update-maintained.sh`, `users/alc/common.nix`, `justfile`; amends ADR-0069 and ADR-0087

## Context

ADR-0069 pinned the maintained apps to `dev`, so `apps-update` was their only
update path and daily use ran unreleased code. ADR-0086 and ADR-0087 then gave
the tools a released command (`tools-update`, `main`) and a dev command
(`dev-tools-update`, `dev`). ADR-0087 kept the apps out of that model on the
claim that Grove, Canopy and Bivrost do not promote to `main` or publish
releases. That claim was wrong: all three, and Paperflow, are tagged on `main`
(Grove v0.9.2, Canopy v0.2.1, Bivrost v0.2.0, Paperflow v0.5.0).

paw and vidown were installed but refreshed by no command, and vidown had no
branch set, so it followed whatever the repository's default branch was.

## Decision

The apps use the same released and dev split as the tools.

- `apps-update` (a shell alias, also `just apps-update`) refreshes the
  released apps on `main`: Grove and Canopy.
- `dev-apps-update` (also `just dev-apps-update`; `qaup` and `just qa-update`
  stay as old names) refreshes the dev builds on `dev`:
  - `grove-dev` and `canopy-dev`, installed on xyz next to the releases. They
    only take a `-dev` command name and share the release's configuration,
    cache and log. Changing their XDG paths would also move the state of the
    editors and git tools they open.
  - paw and vidown, which do not publish releases yet. They keep their own
    names and gain a released pin when they start versioned releases.
  - Paperflow, DankSession, the DMS bundle and the maintained plugins, which
    cannot run twice on one host. They stay on `dev` until a released and dev
    split is worth designing for them. `dms-update` still refreshes the DMS
    subset.
  - Bivrost, which bn-bootstrap installs as a single copy. Its `main` (v0.2.0)
    lacks the route-scope hardening on `dev` (bivrost #54): it accepts more
    Microsoft hosts as private routes and rejects profiles that use
    `allowed_route_suffixes`. It moves to `apps-update` once a release
    carries that fix. bn-bootstrap itself is updated on its own and is in
    neither command.

Like the tool commands, both only change `flake.lock`, and the four update
lists do not overlap. A released app gains a dev pair when its repository has
a `dev` branch that gets ahead of `main`.

## Alternatives and consequences

- **Keep the apps on `dev` (ADR-0069):** daily use runs unreleased code, and
  the released builds that the repositories publish are never installed.
- **Release every app before switching:** `dev` is ahead of `main` in most
  apps. With the dev builds installed next to the releases, nothing is lost
  meanwhile, so releases can follow each project's own pace.
- **Give the dev builds their own XDG state:** isolates their caches but
  also changes where lazygit and the editor keep their state when opened from
  the dev build.

Daily `grove` and `canopy` now run their last release, which lags `dev` until
the next one. A single-copy app moves to `main` only when its release has
everything daily use depends on, since there is no dev build to fall back on.
Each dev input adds a build to the activations that install it, and a broken
dev build blocks `hmsw` until it is fixed or rolled back with the previous
lock.
