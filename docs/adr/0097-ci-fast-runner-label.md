# ADR-0097: Route opted-in CI jobs to fast hosts with a `ci-fast` label

**Status:** Accepted; xyz and xev serve `ci-fast` from their pool runners
**Date:** 2026-10-15
**Amended:** 2026-10-31, the standby controller is retired ([ADR-0106](0106-runner-hold-for-games-and-low-disk.md)); 2026-11-03, the dedicated `xyz-fast` and `xev-fast` runners are retired and the pool runners serve `ci-fast` ([#957](https://git.alc.xyz/alcxyz/nix-config/issues/957)); 2026-11-05, a second pool slot on xyz as a trial ([#991](https://git.alc.xyz/alcxyz/nix-config/issues/991)); 2026-11-05, a runner restart pauses the runner instead of waiting for an idle host ([ADR-0041](0041-native-forgejo-actions-runners.md)); 2026-11-08, one pool slot on xyz and xev ([#1027](https://git.alc.xyz/alcxyz/nix-config/issues/1027))
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
- xyz and xev serve `ci-fast` from their Podman pool runners, beside
  `forgejo-podman` and in the same job slots: two on xyz, two on xev.
  Forgejo has no runner preference: whichever runner polls first takes a job,
  so fast jobs also run while xyz holds its runners for a game.
- Workflows opt in per heavy job with
  `runs-on: ${{ vars.CI_FAST == 'true' && 'ci-fast' || 'forgejo-podman' }}`.
  The switch is a repository Actions variable, set and cleared without commits.
  A boolean is used rather than a free-form label variable, because a mistyped
  label strands the job.
- Each host runs one Podman runner unit beside its Docker runner; the runner
  module has no extra Podman runner units. Podman and Docker runner label
  names never overlap. xyz and xev each run up to two jobs in their one build
  slice (one Docker, one pool).

Workflow authors use [CI runner labels](../ci-runner-labels.md).

## Alternatives Considered

- **Dedicated fast runners.** A one-slot runner unit per host that took only
  `ci-fast` jobs, `xyz-fast` and `xev-fast`, so fast jobs never waited for a
  pool slot. Across 6,400 CI jobs in the 14 days to 2026-11-03 neither took a
  single job; `xev-fast` took none since it started on 2026-10-23. Typical jobs
  take about 2 minutes (p90 about 5), so a pool slot frees quickly. Each cost
  a registration and a unit, and the module needed extra runner units and
  shared labels for them.
- **A purpose set (`ci-fast`, `ci-heavy` on xyz and xev, `ci-light` on nex and
  nux).** More expressive, but no workflow needs the other two labels yet.
- **Host-class labels (`ci-workstation`, `ci-server`, `ci-cluster`).** Names
  hosts rather than needs and still requires the fallback.
- **A standby fast runner on xev that ran only while xyz's was down**, read
  from a status endpoint on xyz. It kept fast jobs on xyz whenever xyz was up,
  but needed a controller, an endpoint and a firewall rule, and xyz's pressure
  drains made it switch often. With xyz's runners held only for games, a
  runner on xev that serves `ci-fast` all the time is simpler; fast jobs land
  on xev also while xyz is free.
- **A user-wide switch.** Works with the same expression, because a
  repository value overrides a user value, but would route every adopting
  repository to xyz at once. It remains possible later.

## Consequences

- With the variable unset, workflows behave as before.
- Fast jobs share the pool slots: they wait while the xyz and xev pool
  slots are both busy or held, and a running fast job delays pool jobs. A
  fast job may land on xev while xyz is free.
- During a game on xyz, or while xyz is off, xev serves fast jobs.
- Runner labels are declared when the daemon starts, and the runner units do not
  restart on switch, so a label change takes effect only after the runner
  restarts (`forgejo-runner-restart`, started by `nixfleet runners restart`,
  restarts it once its running jobs finish; [ADR-0041](0041-native-forgejo-actions-runners.md))
  or the host reboots.
