# ADR-0069: Maintained project development QA inputs

**Status:** Accepted
**Date:** 2026-09-08
**Applies to:** `flake.nix`, maintained project input updates

## Context

The maintainer needs to exercise integrated development changes before making
official releases. A consumer pinned to a release branch cannot provide that
feedback, and changing the consumer's own Git branch does not select matching
branches in its dependencies. Updating a source bundle alone does not reliably
refresh all independent overridden plugin inputs and can restore bundle pins.

## Decision

Use explicit GitHub `dev` inputs for Paperflow, Grove, Canopy, DankSession,
the DMS bundle, and its maintained plugin sources. Keep exact revisions in the
lockfile. This flake is the maintainer QA consumer; source projects retain
`feature/*` → `dev` → `main` promotion, with releases from `main` only.
Keep `dev` current with released fixes: after promotion, fast-forward it to the
resulting main commit when possible, or integrate main without rewriting dev
history. A development branch must not silently lose released fixes.

Retain ADR-0015's aggregate source interface. Set persistent nested overrides
in nix-config rather than changing the public aggregate's release defaults.
Make the aggregate DankSession input follow the existing top-level input, so
there is one revision for its source and package. Continue building each other
plugin helper from the same source used for its widget.

The `qaup` shell shortcut (also available as `just qa-update`) explicitly
refreshes the maintained app and nested plugin inputs from this checkout,
without requiring a development shell. The scheduled DMS updater refreshes
the DMS subset even when the aggregate commit has not changed, then validates
the resulting consumer.
Rebuild and switch commands continue to use committed or reviewed lockfiles;
they do not implicitly fetch branch heads. No source changes, branch promotion,
release, or activation is an implicit side effect of the QA update command.

Leave upstream dependencies and unrelated internal services on their existing
policies. Additional maintained projects can be added explicitly when their
development branch and consumer are known.
WorldClock, DankCalculator, and DMS-Screenshot are upstream forks and are
excluded from the maintained development overrides and explicit QA refreshes.

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
