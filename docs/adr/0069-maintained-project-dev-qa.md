# ADR-0069: Maintained project development QA inputs

**Status:** Accepted
**Date:** 2026-09-08
**Amended:** 2026-10-28
**History:** [replaced text](archive/0069-maintained-project-dev-qa-history.md)
**Applies to:** `flake.nix`, maintained project input updates

## Context

The maintainer needs to exercise integrated development changes before making
official releases. A consumer pinned to a release branch cannot provide that
feedback, and changing the consumer's own Git branch does not select matching
branches in its dependencies. Updating a source bundle alone does not reliably
refresh all independent overridden plugin inputs and can restore bundle pins.

## Decision

This flake is the maintainer QA consumer of the maintained projects' `dev`
branches, through explicit `dev` inputs whose exact revisions stay in the
lockfile. Source projects retain `feature/*` to `dev` to `main` promotion,
with releases from `main` only. Keep `dev` current with released fixes: after
promotion, fast-forward it to the resulting main commit when possible, or
integrate main without rewriting dev history. A development branch must not
silently lose released fixes.

Daily use runs released builds, and the `dev` inputs are the QA side of that
split. These run `dev` daily: paw and vidown until they publish versioned
releases, and Paperflow, DankSession and the DMS plugins, which cannot run
twice on one host:

- Released platform tools follow `main` through `tools-update`
  ([ADR-0086](0086-released-tool-inputs.md)). Their dev builds
  (`paperless-tools-dev`, `regnskap-dev`, `t3rry-dev`) sit next to them and
  are refreshed by `dev-tools-update`
  ([ADR-0087](0087-side-by-side-dev-tools.md)), not `dev-apps-update`.
- Released apps (Grove, Canopy, Bivrost) follow `main` through `apps-update`,
  and `dev-apps-update` refreshes the app `dev` inputs
  ([ADR-0089](0089-released-and-dev-app-inputs.md)): the side-by-side dev
  builds `grove-dev`, `canopy-dev` and `bivrost-dev`; paw and vidown, which
  have no versioned releases yet; and Paperflow, DankSession, the DMS bundle
  and its maintained plugins, which cannot run twice on one host.
- Bivrost is a flake input installed here on Linux and macOS
  ([ADR-0090](0090-install-bivrost-directly.md)); its released `main` branch
  remains the default for other consumers.

Retain ADR-0015's aggregate source interface. Set persistent nested overrides
in nix-config rather than changing the public aggregate's release defaults:
the `dms-plugins` input follows its `dev` branch and overrides the maintained
plugin sources (quicksearch, vault, translate, spotify, dankcalendar,
diskusage, aiusage, displaycontrol) to their `dev` branches. Make the
aggregate DankSession input follow the existing top-level input, so there is
one revision for its source and package. Continue building each other plugin
helper from the same source used for its widget.

`dev-apps-update` (a shell alias, also `just dev-apps-update`) explicitly
refreshes the maintained app `dev` inputs listed above, the nested plugin
inputs and the private `work` input
([ADR-0089](0089-released-and-dev-app-inputs.md)) from this checkout, without requiring a development shell; `qaup` and `just qa-update`
remain compatibility names for it. `dms-update` (or `just dms-update`)
refreshes only the DMS subset: the bundle, DankSession and the nested plugin
inputs. The scheduled DMS updater (the `nix-dms-update` user service and
timer on xyz) refreshes the DMS subset even when the aggregate commit has not
changed, then validates the resulting consumer.
Rebuild and switch commands continue to use committed or reviewed lockfiles;
they do not implicitly fetch branch heads. No source changes, branch promotion,
release, or activation is an implicit side effect of an update command.

Leave upstream dependencies and unrelated internal services on their existing
policies. Additional maintained projects can be added explicitly when their
development branch and consumer are known.
WorldClock, DankCalculator, and DMS-Screenshot are third-party plugins and are
excluded from the maintained development overrides and explicit QA refreshes.
The bundle takes them from their upstream repositories at exact revisions
(dms-plugins ADR-004, 2026-10-17), replacing the earlier forks pinned on `main`.

## Alternatives and consequences

- Release every change before testing: removes the useful QA stage.
- Temporary local path overrides: do not survive normal lock refreshes and
  cannot identify a shared, reproducible development revision.
- Change the public aggregate's defaults to dev: changes what other consumers
  receive and makes release consumers opt out of maintainer QA.
- Fetch latest revisions on every rebuild: mixes update and activation and
  makes failures harder to reproduce.

Development revisions can regress. Keep QA pins reviewable and use existing
Nix/Home Manager generations or prior lockfiles to roll back. A successful
build is not runtime QA, and a successful QA update is not a source release.
