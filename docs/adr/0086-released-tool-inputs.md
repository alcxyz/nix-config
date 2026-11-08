# ADR-0086: Refresh released platform tools from main

**Status:** Accepted
**Date:** 2026-10-09
**Amended:** 2026-10-28, updated 2026-10-29 (devstats added to the tool list, per owner decision), updated 2026-10-30 (videdupe removed from the tool list: vidown ADR-023 replaces it, per owner decision), 2026-11-08 (update groups of `just update`, [ADR-0107](0107-update-entry-point-builds-before-commit.md))
**History:** [replaced text](archive/0086-released-tool-inputs-history.md)
**Applies to:** `flake.nix`, `scripts/update-inputs/update.py`; amends ADR-0069

## Context

The owner's own command-line tools reached the workstation in different ways.
paperweight (paperless-tools) was a flake input on `main` that was refreshed only
by naming it to `nix flake update`. reportcraft, stashdb-pop and videdupe followed
their default branch. bokfor (regnskap) was not packaged: it ran from the regnskap
checkout, at whatever branch that checkout had. `apps-update` (ADR-0069) covered
only the dev-branch QA apps and the DMS plugins, so nothing kept the tools
current. Unlike the QA apps, these tools do real work against the archive and
the accounts, so they should run released code.

## Decision

The `tools` group of `just update` ([ADR-0107](0107-update-entry-point-builds-before-commit.md)) refreshes one explicit
list of tool inputs, each following its repository's released `main` branch:
paperless-tools, regnskap, reportcraft, stashdb-pop, t3rry, hedgedoc and
devstats. The `tools` list in `scripts/update-inputs/update.py` is the current
list. Tools on Forgejo write the branch explicitly as `?ref=main`; tools
hosted on GitHub, such as t3rry, pin `github:alcxyz/<repo>/main` instead.
`just update tools` builds the fleet and commits only `flake.lock` when the
build passes; the owner activates it with `hmsw`. Its list does not overlap
with the `dev-tools` group ([ADR-0087](0087-side-by-side-dev-tools.md)) or
the app groups ([ADR-0089](0089-released-and-dev-app-inputs.md)).

regnskap provides a flake package for bokfor at its `VERSION` release, and xyz
installs it next to paperweight. The documented workflow still runs it from
the checkout's `cmd/bokfor` directory (`direnv exec . bokfor …`), which holds
its environment and configuration. The `bokfor-dev` launcher runs the regnskap
dev build against the sandbox (ADR-0087). hedgedoc's CLI is exposed as
`pkgs.hedgedoc-cli`, because nixpkgs' `hedgedoc` is the server. devstats
provides a flake package and the Home Manager module that runs its nightly
collector on xyz; the `tools` group refreshes both.

A tool joins the list when its repository releases from `main` and has a flake
package. vidown has no versioned releases yet, so it follows `dev` under its
own name in the `dev-apps` group (ADR-0089) rather than this list. Services
such as Timebank and the deployed bokfor-admin keep their own deployment
paths.

## Alternatives and consequences

- **Add the tools to the `apps` group:** this mixes released tools with the
  app lists and changes what that group means.
- **Keep running bokfor from the checkout:** its version then depends on
  whichever branch another task left checked out.
- **Follow `dev` for the tools as well:** daily bookkeeping would run unreleased
  code. Dev builds are installed side by side instead (ADR-0087).

A tool's flake must keep building at `main`. For Go tools, a stale `vendorHash`
after a dependency change fails the fleet build of `just update tools`,
which then leaves the lock uncommitted; the previous lock and generation
remain the rollback.
