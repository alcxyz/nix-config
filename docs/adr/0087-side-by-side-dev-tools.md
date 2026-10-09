# ADR-0087: Install dev builds of released tools side by side

**Status:** Accepted, amended by [ADR-0089](0089-released-and-dev-app-inputs.md) (apps get the same split)
**Date:** 2026-10-09
**Applies to:** `flake.nix`, `flake/pkgs.nix`, `scripts/update-inputs/update-dev-tools.sh`, `users/alc/common.nix`, `justfile`; amends ADR-0086

## Context

ADR-0086 put the owner's tools on their released `main` branches, so daily work
runs released code. A change on a tool's `dev` branch then had no installed
build: checking it against real data meant building a checkout by hand, and
the `bokfor-dev` launcher in nix-secrets ran `go run` from whatever branch the
regnskap checkout had. Of the released tools, only paperless-tools and regnskap
have a `dev` branch that gets ahead of `main`.

## Decision

`dev-tools-update` (a shell alias, also `just dev-tools-update`) refreshes a
second, separate pair of inputs, `paperless-tools-dev` and `regnskap-dev`, which
follow `?ref=dev`. Like `tools-update`, it only changes `flake.lock`; the owner
inspects the change and activates it with `hmsw`. The two lists and the
`apps-update` list do not overlap.

- `paperweight-dev` is installed on xyz next to `paperweight`. It wraps the dev
  build and sets `XDG_STATE_HOME` to `~/.local/state/paperweight-dev`, so its
  audit and retitle reports stay apart from the release's. It shares the
  release's configuration, so it reaches the same Paperless instances.
  paperweight reads `XDG_STATE_HOME` only for its reports and gives the `claude`
  and `codex` CLIs an allowlisted environment without it.
- `pkgs.bokfor-dev` is the regnskap dev build. It is not installed directly: the
  `bokfor-dev` launcher in nix-secrets runs it against the Visma sandbox and dev
  Paperless, in place of `go run` from the checkout.

A released tool gains a dev pair when its repository has a `dev` branch that
gets ahead of `main`.

## Alternatives and consequences

- **Pin the released tools to `dev`:** daily bookkeeping and archive work would
  run unreleased code, which ADR-0086 rejected.
- **Build dev versions from a checkout by hand:** the version then depends on
  which branch another task left checked out, as with the old launcher.
- **Pair the maintained apps as well (`dev-apps-update`):** left out here on
  the claim that Grove, Canopy and Bivrost do not promote to `main` or publish
  releases. That was wrong, since all three are tagged on `main`, and ADR-0089
  pairs Grove and Canopy. Paperflow is a single-instance folder-watching service, and two
  copies would compete for the same files. The DMS plugins stay on
  `dms-update`, because two copies of one widget in one shell make no sense.

Each dev input adds a build to every activation that installs it, and the dev
flake must keep building. A broken dev build blocks `hmsw` until it is fixed or
the dev input is rolled back with the previous lock.
