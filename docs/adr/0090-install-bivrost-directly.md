# ADR-0090: Install Bivrost directly, configured by the work flake

**Status:** Accepted; since 2026-10-18 `apps-update` and `dev-apps-update` refresh the work flake instead of updating it on its own (amendment in [ADR-0089](0089-released-and-dev-app-inputs.md))
**Date:** 2026-10-10
**Applies to:** `flake.nix`, `flake/pkgs.nix`, `users/alc/linux/operator.nix`, `users/alc/darwin/mac.nix`, `flake/checks/default.nix`; amends ADR-0069 and ADR-0089

## Context

Bivrost was installed by the private work flake's Home Manager module, which built it
from a source input that followed this flake's `bivrost` input and wrapped it
with the work catalogue. The Bivrost version was therefore chosen here but
built there, and only one Bivrost could be installed, because the catalogue
existed only inside that wrapper. Bivrost is now a neutral public tool with its
own flake package, and it reads `catalogue.json` from its configuration
directory (Bivrost ADR 0017). The work flake's module writes that file and can
leave installation to the machine (that flake's ADR-012).

## Decision

On the operator hosts and the mac, this flake installs `pkgs.bivrost` from the
Bivrost flake and sets `programs.work.bivrost.package = null`.
The work flake's module still supplies the catalogue, profiles and work
sign-in browser rule. `bivrost` becomes a flake input, replacing ADR-0069's
non-flake source input, and the work flake no longer follows it, so
it is updated on its own, as ADR-0089 already treats it. Its own
locked Bivrost source is then unused while the package option is unset.

Bivrost stays on `dev` in `dev-apps-update` until a release carries the
route-scope hardening and the configuration catalogue. It then moves to
`apps-update` on `main`, and a `bivrost-dev` build can sit beside it, since
both read the same configuration. Bivrost v0.3.0 carried both changes, so
on 2026-10-10 `bivrost` moved to `apps-update` on `main` and `bivrost-dev` was
installed on xyz.

## Alternatives and consequences

- **Keep installing through the work flake:** a Bivrost version change needs a
  work flake change, and a dev build cannot sit next to the release.
- **Set the package option to this flake's Bivrost:** keeps installation in
  the module that should only carry work configuration.

Removing the work flake's module now removes the work configuration but
leaves a working neutral Bivrost. A check asserts that every operator home
installs `pkgs.bivrost` and leaves the module's package unset.
