# ADR-0097: Route opted-in CI jobs to fast hosts with a `ci-fast` label

**Status:** Accepted; xyz serves `ci-fast`, the xev fallback is pending
**Date:** 2026-10-15
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

xyz's admission control drains its runners with a graceful `systemctl stop`
while a game runs or under pressure or low disk, and Forgejo then reports them
`offline` within about a minute. A busy runner stays online.

## Decision

- Add one purpose label, `ci-fast`, meaning "run on a fast host or wait". It is
  never served by nex or nux. `forgejo-podman` stays the default shared pool on
  all four hosts.
- xyz serves `ci-fast`. xev serves it only while xyz's fast runner is offline,
  through a separate xev runner instance that a controller on xev starts and
  stops from Forgejo's runner status, with hysteresis. Running jobs always
  finish where they started.
- Workflows opt in per heavy job with
  `runs-on: ${{ vars.CI_FAST == 'true' && 'ci-fast' || 'forgejo-podman' }}`.
  The switch is a repository Actions variable, set and cleared without commits.
  A boolean is used rather than a free-form label variable, because a mistyped
  label strands the job.
- Rollout is staged. First, `ci-fast` is added to xyz's existing Podman runner,
  so fast jobs share its two job slots with shared-pool jobs. Then the runner
  module supports more than two runner units, which gives xyz a dedicated
  `ci-fast` instance and adds the gated xev instance.

Workflow authors use [CI runner labels](../ci-runner-labels.md).

## Alternatives Considered

- **A purpose set (`ci-fast`, `ci-heavy` on xyz and xev, `ci-light` on nex and
  nux).** More expressive, but no workflow needs the other two labels yet.
- **Host-class labels (`ci-workstation`, `ci-server`, `ci-cluster`).** Names
  hosts rather than needs and still requires the fallback.
- **A heartbeat from xyz to xev.** Could tell gaming apart from pressure drains
  and needs no Forgejo credential, but adds a host-to-host channel with its own
  authentication.
- **An always-on xev instance that polls slowly.** Needs no controller, but xev
  would also take fast jobs whenever xyz is merely busy, and the preference is
  only probabilistic.
- **A user-wide switch.** Works with the same expression, because a
  repository value overrides a user value, but would route every adopting
  repository to xyz at once. It remains possible later.

## Consequences

- With the variable unset, workflows behave as before.
- Until the dedicated xyz instance exists, a `ci-fast` job waits while
  `forgejo-podman` or `forgejo-podman-canary` jobs occupy both slots of xyz's
  Podman runner.
- Until the xev fallback exists, `ci-fast` jobs wait while xyz is gaming or
  off. Afterwards they wait only while both xyz and xev are unavailable.
- xyz pressure and disk drains also trigger the fallback; a busy xyz does not.
- The xev controller needs a read-only Forgejo credential, wired privately.
- Runner labels are declared when the daemon starts, and the runner units do not
  restart on switch, so a label change takes effect only after the runner
  restarts or the host reboots.
- Adding runner units changes the pressure guard's persisted unit registry, so
  that step takes effect only after a reboot.
