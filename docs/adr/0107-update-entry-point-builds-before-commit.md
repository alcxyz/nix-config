# ADR-0107: One update entry point that builds the fleet before committing

**Status:** Accepted
**Date:** 2026-11-08
**Applies to:** `justfile`, `scripts/update-inputs/update.py`, `scripts/update-inputs/update-dms-plugins.sh`, `users/alc/common.nix`, `scripts/checks/test-update-inputs.py`; amends ADR-0069, ADR-0086, ADR-0087, ADR-0089 and ADR-0090

## Context

`just update` ran a plain `nix flake update`, so a lock that did not build
reached `dev` before anything had built it. On 2026-11-08 a full flake update
pulled in nixpkgs' temporary removal of `brave-origin` (removed upstream on
2026-11-03, re-added on 2026-11-07, not yet in `nixos-unstable`). It broke the
xyz Home Manager configuration and xps, while the same `deploy --all` had
already moved every other host to the new nixpkgs.

Six more recipes and their shell aliases (`apps-update`, `dev-apps-update`,
`dms-update`, `qa-update` with its alias `qaup`, `tools-update` and
`dev-tools-update`) were further names for the same `nix flake update` over a
fixed list, and none of them built or committed anything. Tracked in
[#1035](https://git.alc.xyz/alcxyz/nix-config/issues/1035).

## Decision

`just update [NAME...]` (`scripts/update-inputs/update.py`) is the one way to
update flake inputs by hand.

- With no name it updates every input. A name is a group or a flake input
  name, including a nested one such as `dms-plugins/aiusage`, mixed freely;
  an unknown name is rejected before anything runs. The groups keep the lists
  the old recipes had:
  - `tools`: the released platform tools on `main`
    ([ADR-0086](0086-released-tool-inputs.md));
  - `dev-tools`: their dev builds on `dev`
    ([ADR-0087](0087-side-by-side-dev-tools.md));
  - `apps`: the released apps on `main`, plus the shared `work` and
    `teams-chat` inputs ([ADR-0089](0089-released-and-dev-app-inputs.md));
  - `dev-apps`: the maintained apps' dev builds, the DMS bundle, DankSession
    and the maintained plugins, plus `work` and `teams-chat` (ADR-0069,
    ADR-0089);
  - `dms`: only the DMS part of `dev-apps` (ADR-0069).

  `update.py` holds the lists; `update.py --list [NAME...]` prints what the
  names resolve to without changing anything. No group name may be an input
  name.
- It refuses to start while any tracked file, `flake.lock` included, differs
  from `HEAD`, staged or not. The build sees the working tree but the commit
  holds only `flake.lock`, so the build must test exactly what is committed.
  Untracked files are outside a Git flake and do not block.
- It runs `nix flake update` for the resolved inputs. When the lock does not
  change, it says so and exits successfully.
- It then runs `nix flake check --no-build` and `deploy --build-only --all`,
  which builds every host's system and Home Manager configuration that
  `deploy --all` covers from the current checkout without activating
  anything.
- When both pass, it commits `flake.lock` alone with the configured Git
  identity, as `chore(flake): update <all inputs | the names given>`, with
  each changed input and its old and new short revision and date in the body.
  It never pushes.
- When a step fails, it leaves `flake.lock` modified and uncommitted, names
  the failed step and, for the build, the failed targets from deploy's report;
  deploy prints the path of its run record. Undo with `git checkout
  flake.lock`. It exits non-zero. There is no option to skip the build.

Switching stays a separate, explicit `deploy`. The scheduled DMS updater
(`nix-dms-update` on xyz, ADR-0076) keeps its own validation and publication
path; `update-dms-plugins.sh` takes its input list from the `dms` group.
Hosts with `deployAll = false` are outside `--all` and outside this build.

## Alternatives Considered

- **Keep the separate recipes and add a build to each:** seven names for one
  operation, each needing the same guard, and `just update` would still be
  the easiest one to run unguarded.
- **Only a nixfleet safeguard (ask before activating the rest when some
  targets fail):** limits how far a broken lock spreads during a deploy, but
  the lock is already committed and possibly pushed by then. That safeguard
  is tracked separately in nix-packages and complements this one.

## Consequences

- A lock that fails to evaluate or build on any `--all` host is never
  committed by the update command, and the commit message records what moved.
- Every update costs a fleet build on the machine running it, which is the
  build the next `deploy --all` would otherwise run; the Nix store keeps the
  results, so that deploy reuses them.
- A green build is not runtime QA: an update can still build and misbehave,
  and the previous lock and generations remain the rollback.
- The aliases are gone; after the next Home Manager switch the shell no
  longer offers them.
