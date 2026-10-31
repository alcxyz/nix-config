# ADR-0097: Route opted-in CI jobs to fast hosts with a `ci-fast` label

**Status:** Accepted; xyz and xev each serve `ci-fast` with a dedicated runner
**Date:** 2026-10-15
**Amended:** 2026-10-31, `xev-fast` runs all the time and the standby controller is retired ([ADR-0106](0106-runner-hold-for-games-and-low-disk.md))
**History:** [replaced text](archive/0097-ci-fast-runner-label-history.md)
**Applies to:** `hosts/xyz/configuration.nix`, `hosts/xev/configuration.nix`,
`modules/nixos/services/forgejo-actions-runner/`, platform workflows

## Context

Every runner host carries the shared `forgejo-podman` label, so a job lands on
whichever runner polls first. Hosts differ widely: xyz has 32 threads, xev 16,
and nex and nux 8 each while also running k3s, Longhorn and RustFS. An
end-to-end suite that takes about 1.5 minutes on xyz takes 7 to 8 minutes on
nex or nux. Slow CI hurts while a project is being iterated on; slow background
builds do not.

Forgejo label matching has no priority or fallback: a job waits until a runner
carrying its label fetches it. Forgejo 15 evaluates expressions, including
`vars`, in `runs-on`; a job whose label no runner carries waits until the
abandoned-job timeout (24 hours by default).

xyz's runner hold stops its runners gracefully while a game runs or the disk
is low ([ADR-0106](0106-runner-hold-for-games-and-low-disk.md)), and Forgejo
then reports them `offline` within about a minute.

## Decision

- Add one purpose label, `ci-fast`, meaning "run on a fast host or wait". It is
  never served by nex or nux. `forgejo-podman` stays the default shared pool on
  all four hosts.
- xyz and xev serve `ci-fast`, each through a dedicated runner instance with
  one job slot: `xyz-fast` and `xev-fast`. Whichever polls first takes a job,
  so fast jobs also run while xyz holds its runners for a game.
- Workflows opt in per heavy job with
  `runs-on: ${{ vars.CI_FAST == 'true' && 'ci-fast' || 'forgejo-podman' }}`.
  The switch is a repository Actions variable, set and cleared without commits.
  A boolean is used rather than a free-form label variable, because a mistyped
  label strands the job.
- The runner module supports more than two runner units. xyz runs a
  dedicated `ci-fast` instance, `xyz-fast`, with one job slot. xyz's pool
  runner keeps `ci-fast` too, so fast jobs can also start in its free slots.
  Forgejo has no runner preference: whichever runner polls first takes a job.
  This is the one label two runners on a host may share
  (`podmanCanary.sharedLabels`); the Docker runner never shares a label. xyz
  runs up to three jobs in its one build slice (one Docker, one pool and one
  fast), xev up to four (one Docker, two pool and one fast).

Workflow authors use [CI runner labels](../ci-runner-labels.md).

## Alternatives Considered

- **A purpose set (`ci-fast`, `ci-heavy` on xyz and xev, `ci-light` on nex and
  nux).** More expressive, but no workflow needs the other two labels yet.
- **Host-class labels (`ci-workstation`, `ci-server`, `ci-cluster`).** Names
  hosts rather than needs and still requires the fallback.
- **A standby `xev-fast` that runs only while `xyz-fast` is down**, read from
  a status endpoint on xyz. It kept fast jobs on xyz whenever xyz was up, but
  needed a controller, an endpoint and a firewall rule, and xyz's pressure
  drains made it switch often. With xyz's runners held only for games, an
  always-on `xev-fast` is simpler; fast jobs land on xev also while xyz is
  free.
- **A user-wide switch.** Works with the same expression, because a
  repository value overrides a user value, but would route every adopting
  repository to xyz at once. It remains possible later.

## Consequences

- With the variable unset, workflows behave as before.
- `ci-fast` jobs wait only while `xyz-fast`, `xev-fast` and xyz's pool slot
  are all busy or held. A fast job may take xyz's pool slot while `xyz-fast`
  is idle, which delays shared-pool jobs, and may land on xev while xyz is
  free.
- During a game on xyz, or while xyz is off, `xev-fast` serves fast jobs.
- Runner labels are declared when the daemon starts, and the runner units do not
  restart on switch, so a label change takes effect only after the runner
  restarts or the host reboots.
- A runner unit added by a switch starts at the switch, since the runner hold
  keeps no unit registry.
