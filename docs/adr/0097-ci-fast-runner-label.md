# ADR-0097: Route opted-in CI jobs to fast hosts with a `ci-fast` label

**Status:** Accepted; xyz serves `ci-fast` with a dedicated runner, and xev with a standby runner while that one is down
**Date:** 2026-10-15
**Amended:** 2026-10-29
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

xyz's admission control drains its runners with a graceful `systemctl stop`
while a game runs or under pressure or low disk, and Forgejo then reports them
`offline` within about a minute. A busy runner stays online. Forgejo lists
instance-wide runners only to tokens with the `read:admin` scope.

## Decision

- Add one purpose label, `ci-fast`, meaning "run on a fast host or wait". It is
  never served by nex or nux. `forgejo-podman` stays the default shared pool on
  all four hosts.
- xyz serves `ci-fast`. xev serves it only while xyz's fast runner is down,
  through a standby xev runner instance, `xev-fast`, with one job slot. xyz
  publishes that runner unit's systemd state. Its firewall admits the
  endpoint only on the NetBird interface and the socket only NetBird
  addresses, and NetBird's peer keys authenticate the two hosts. A controller on xev polls
  it every 15 seconds and starts `xev-fast` after a minute without an
  `active` answer, no answer included. It stops `xev-fast` gracefully once
  xyz's runner has been back for five minutes. Running jobs always finish
  where they started.
- The standby unit stays enabled, so xev's pressure and disk drains cover it.
  Its start gate refuses it until the controller admits it, so the guard's
  resume after a drain cannot start it while xyz's runner is up.
- Workflows opt in per heavy job with
  `runs-on: ${{ vars.CI_FAST == 'true' && 'ci-fast' || 'forgejo-podman' }}`.
  The switch is a repository Actions variable, set and cleared without commits.
  A boolean is used rather than a free-form label variable, because a mistyped
  label strands the job.
- The runner module supports more than two runner units. xyz runs a
  dedicated `ci-fast` instance, `xyz-fast`, with one job slot. xyz's pool
  runner keeps `ci-fast` too, so fast jobs can also start in its free slots.
  Forgejo has no runner preference: whichever runner polls first takes a job.
  This is the one label two runners may share (`podmanCanary.sharedLabels`);
  the Docker runner never shares a label. xyz runs up to five jobs in its one
  build slice: one Docker, three pool and one fast.

Workflow authors use [CI runner labels](../ci-runner-labels.md).

## Alternatives Considered

- **A purpose set (`ci-fast`, `ci-heavy` on xyz and xev, `ci-light` on nex and
  nux).** More expressive, but no workflow needs the other two labels yet.
- **Host-class labels (`ci-workstation`, `ci-server`, `ci-cluster`).** Names
  hosts rather than needs and still requires the fallback.
- **The controller reads Forgejo's runner status.** Needs no channel between
  the hosts, but Forgejo lists instance-wide runners only to `read:admin`
  tokens, which would put an admin-read token on xev for one bit of state.
  The status endpoint is used instead because NetBird already authenticates
  the hosts; only that authentication concern had ruled out a host-to-host
  channel.
- **xyz pushes a heartbeat to xev.** Gives the same answers, but needs a
  listener on xev and an expiry rule. Polling keeps xyz passive and makes "no
  answer" mean down.
- **An always-on xev instance that polls slowly.** Needs no controller, but xev
  would also take fast jobs whenever xyz is merely busy, and the preference is
  only probabilistic.
- **A user-wide switch.** Works with the same expression, because a
  repository value overrides a user value, but would route every adopting
  repository to xyz at once. It remains possible later.

## Consequences

- With the variable unset, workflows behave as before.
- `ci-fast` jobs on xyz always have the dedicated slot available to them, and
  wait only while it and all three pool slots are busy. A fast job may still take a
  pool slot while `xyz-fast` is idle, which delays shared-pool jobs.
- The build slice's CPU and memory budget is unchanged, so five concurrent
  jobs on xyz each get a smaller share under load.
- `ci-fast` jobs wait only while both xyz's runners and `xev-fast` are
  unavailable. A fallback begins about a minute after `xyz-fast` stops and ends
  five minutes after it returns; a job `xev-fast` has started finishes on xev.
- xyz's game, pressure and disk drains and an xyz that is off all trigger the
  fallback; a busy xyz does not.
- The fallback needs no credential. The polls leave only through NetBird, so a
  missing route cannot reach another host. If the link fails while xyz is up,
  or NetBird takes over a minute to connect after xev boots, both hosts serve
  `ci-fast` until it recovers, which is harmless.
- Stopping the xev controller releases `xev-fast` until the next switch or
  boot starts the controller again; masking `xev-fast` keeps it off for good.
  A switch does not restart a running controller, because a release would end
  a running fallback for as long as its job runs; a changed controller takes
  effect at the next boot or an explicit restart.
- Any NetBird peer can query the endpoint, and enough slow clients can fill
  its few connection slots. Either only reveals one systemd state or makes xev
  serve `ci-fast` as well, which is harmless.
- `xev-fast` registers with Forgejo at its first start, so Forgejo lists it only
  after the first fallback.
- Runner labels are declared when the daemon starts, and the runner units do not
  restart on switch, so a label change takes effect only after the runner
  restarts or the host reboots.
- Adding a runner unit changes the pressure guard's persisted unit registry,
  so it takes effect only after a reboot. Reboot a host right after switching
  to a configuration that adds a runner unit: until then the start gates
  refuse the new unit, and the first drain would leave the runners stopped.
