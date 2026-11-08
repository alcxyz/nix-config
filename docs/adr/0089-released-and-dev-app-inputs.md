# ADR-0089: Released and dev app inputs

**Status:** Accepted
**Date:** 2026-10-10
**Amended:** 2026-10-28, 2026-11-04 (the `teams-chat` input), 2026-11-08 (update groups of `just update`, [ADR-0107](0107-update-entry-point-builds-before-commit.md))
**History:** [replaced text](archive/0089-released-and-dev-app-inputs-history.md)
**Applies to:** `flake.nix`, `flake/pkgs.nix`, `scripts/update-inputs/update.py`; amends ADR-0069 and ADR-0087

## Context

ADR-0069 pinned the maintained apps to `dev`, so `apps-update` was their only
update path and daily use ran unreleased code. ADR-0086 and ADR-0087 then gave
the tools a released command (`tools-update`, `main`) and a dev command
(`dev-tools-update`, `dev`). ADR-0087 kept the apps out of that model on the
claim that Grove, Canopy and Bivrost do not promote to `main` or publish
releases. That claim was wrong: all three, and Paperflow, are tagged on `main`
(Grove v0.9.2, Canopy v0.2.1, Bivrost v0.2.0, Paperflow v0.5.0 at the time).

paw and vidown were installed but refreshed by no command, and vidown had no
branch set, so it followed whatever the repository's default branch was.

## Decision

The apps use the same released and dev split as the tools.

- The `apps` group of `just update` ([ADR-0107](0107-update-entry-point-builds-before-commit.md)) refreshes the
  released apps on `main`: Grove, Canopy and Bivrost. Bivrost moved here on
  2026-10-10 with v0.3.0, which carried the route-scope
  hardening (bivrost #54) and the configuration catalogue; it is installed
  from its own flake and configured by the private work flake
  ([ADR-0090](0090-install-bivrost-directly.md)).
- The `dev-apps` group refreshes the dev builds on `dev`:
  - `grove-dev`, `canopy-dev` and `bivrost-dev`, installed on xyz next to the
    releases under a `-dev` command name. `grove-dev` and `canopy-dev` share
    the release's configuration, cache and log, since changing their XDG
    paths would also move the state of the editors and git tools they open.
    `bivrost-dev` reads the same configuration catalogue as the release,
    which the work flake writes ([ADR-0090](0090-install-bivrost-directly.md)).
  - paw and vidown, which do not publish releases yet. They keep their own
    names and gain a released pin when they start versioned releases.
  - Paperflow, DankSession, the DMS bundle and the maintained plugins, which
    cannot run twice on one host. They stay on `dev` until a released and dev
    split is worth designing for them. The `dms` group refreshes only the
    DMS subset (ADR-0069).
- The private work flake (input `work`) is in both groups. It stays one
  input on its `dev` branch, whose `main` is not promoted, so either group
  keeps its configuration current. Its Forgejo SSH URL makes `just update
  apps` depend on Forgejo SSH access, as `dev-apps` already does for vidown.
- The private `teams-chat` flake is in both groups in the same way, on its
  `dev` branch over Forgejo SSH. `work` and `teams-chat` are the only inputs
  the update lists share.

Like the tool groups, both commit only `flake.lock`, after the fleet builds,
and apart from `work` and `teams-chat` the four groups (`tools`, `dev-tools`,
`apps`, `dev-apps`) do not overlap; `dms` is the DMS part of `dev-apps`. The
`apps` and `dev-apps` lists in `scripts/update-inputs/update.py` are the
current app lists. A
released app gains a dev pair when its repository has a `dev` branch that
gets ahead of `main`.

## Alternatives and consequences

- **Keep the apps on `dev` (ADR-0069):** daily use runs unreleased code, and
  the released builds that the repositories publish are never installed.
- **Release every app before switching:** `dev` is ahead of `main` in most
  apps. With the dev builds installed next to the releases, nothing is lost
  meanwhile, so releases can follow each project's own pace.
- **Give the dev builds their own XDG state:** isolates their caches but
  also changes where lazygit and the editor keep their state when opened from
  the dev build.
- **Update the work flake on its own, in neither group:** a catalogue change
  once stayed undeployed because no command refreshed it.

Daily `grove`, `canopy` and `bivrost` run their last release, which lags
`dev` until the next one. A single-copy app moves to `main` only when its
release has everything daily use depends on, since there is no dev build to
fall back on. Each dev input adds a build to the activations that install it,
and a broken dev build blocks `hmsw` until it is fixed or rolled back with the
previous lock.
