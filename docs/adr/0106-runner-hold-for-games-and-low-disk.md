# ADR-0106: Hold the CI runners while a game runs or the disk is low

**Status:** Accepted
**Date:** 2026-10-31
**Applies to:** `modules/nixos/services/forgejo-actions-runner/runner-hold.{nix,sh}`,
`runner-start-gate.sh`, `modules/nixos/services/game-signal/`, the runner pool
on xyz, xev, nex and nux, and the Wolf and DMS background builds on xyz

## Context

The runner guards began as protection for gaming on xyz: CI must not take the
desktop's resources while a game runs. They grew into an I/O pressure guard
that drained admission at moderate host pressure, froze the build aggregate
at severe pressure, thawed a freeze or resumed a drain after a settled
interval, and needed a teardown boundary for frozen workers, a standby
controller for `ci-fast`, a hold monitor and persistent, generation-bound
drain ownership. Host-wide PSI does not attribute pressure: from 2026-10-24 to
2026-10-31 the guard logged 932 runner drain events on xyz, 411 on xev, 16 on
nex and 14 on nux, much of it for load that CI did not cause. On 2026-10-31 a
drain and repeated freezes used up a runner's one-hour stop timeout; systemd
killed it, it stayed `failed`, and the guard, which resumes only inactive
runners, never started it again.

The game detector matched one Wine game. From 2026-09-22 it drained the
runners 16 times for a game and 159 times for an uncertain scan, mostly
processes exiting during the scan. Steam games, the sideloaded Heroic games
and SteamHeadless streams to xps went unseen.

xyz's CI stores are on their own SSD pool, but ZFS ignores cgroup I/O weights
for buffered writes and limits dirty data for all pools together, so heavy CI
writes also slow the pools that Plex, qBittorrent, Stash and Calibre use. The
number of concurrent jobs is the lever that works.

## Decision

**One game signal.** `services.gameSignal` defines once what counts as a game
on a host: Wine games by the basename of the first argument of the user's
`wine64-preloader` processes (no other argument and no process environment is
read), exact process names of the user, and UDP ports a stream server binds
only while a client streams. A root `game-signal` service scans every
5 seconds and publishes the answer as `/run/game-signal/active`, which exists
while a game runs and for a 60-second cooldown after the last one. One
uncertain scan changes nothing; three in a row count as a game. On xyz the
signal covers Heroes of the Storm and the sideloaded Heroic games (not the
Battle.net launcher), Steam's `reaper`, and Sunshine's video port 47998.
SteamHeadless runs its games as uid 1000, the operator's, and Sunshine on the
host network, so a stream to xps is seen either way. The reboot guard uses the
same lists through the same scan, without the cooldown.

**One runner hold.** `forgejo-runner-hold` replaces the pressure guard, its
drain, freeze, settled thaw and lifecycle teardown, the `ci-fast` standby
controller and the hold monitor on every runner host. Every 5 seconds it
looks at its hold reasons: a game (xyz only, `runnerHold.game`; an inactive
game signal counts as a game) and free space below the disk floor (every
host, `runnerHold.diskSpace`: hold below 30 GiB or 15%, release at 40 GiB and
20%). While a reason applies it marks each running runner `held` and stops
it. Once none applies, it resets and starts every marked runner that is
inactive or failed, so a stop that timed out no longer strands a runner, and
retries a refused start with spacing that doubles up to 5 minutes; the
marker goes once the start has passed its gate, and systemd owns any restart
after that. A runner stopped by anyone else has no marker and is never
started, except a stop in the few seconds between the hold's start request
and the start passing its gate; disabling or masking a marked runner drops
its marker. The controller keeps no other
state, restarts freely, and nothing binds to it: losing it stops no runner or
engine, and the storage monitor reports it, as it reports the game signal.

**Stops are ordinary runner stops.** A runner stopped for any reason stops
polling and waits for its running jobs up to `shutdownTimeoutSeconds`, then
cancels them; systemd's stop timeout adds 300 seconds for the cancellation
and container cleanup. xyz uses 120 seconds, so a game gets the disk back
within about two minutes and longer jobs are cancelled; xev, nex and nux keep
3600 seconds. Nothing freezes the build aggregate any more, so a stopping
runner always makes progress.

**Start gate.** Each runner's root `ExecCondition` refuses a start while a
hold reason applies and leaves the `held` marker, so boot, a switch or a
Podman store reset cannot start a runner behind a game or a full disk, and
the hold starts it later. The gate and both engine APIs take the start lock
in `/run/forgejo-runner-hold` before they start, which orders every start
after a store reset's rename ([ADR-0105](0105-offline-podman-store-reset.md)).

**Left-off runners are reported.** Every 5 minutes the hold pings the host's
`ci-runners-<host>` Healthchecks check, reusing the storage monitor's private
ping base. A runner that has not been running for 30 minutes fails the ping,
unless a hold reason applies, a running store reset will start it, or it
carries a marker while it drains its jobs. After a hold ends the count starts
again, so a runner whose start keeps failing, is refused or crash-loops is
reported 30 minutes later.

**Fewer slots.** xyz runs three CI slots instead of five (one Docker, one
pool, one `ci-fast`) with a 25% memory throttle and a 35% hard limit. xev runs
four (one Docker, two pool, one `ci-fast`): from 2026-10-24 to 2026-10-31 its
jobs ran three or more at once for about a third of its busy time. nex and nux
keep one slot per runner. `xev-fast` now runs all the time beside `xyz-fast`
([ADR-0097](0097-ci-fast-runner-label.md)).

**Background builds follow the signal.** On xyz the Wolf image context
producer and the DMS updater skip their runs while the game signal file
exists, instead of waiting for a runner to be active.

## Alternatives Considered

- **Keep the pressure drain with better thresholds.** Host-wide PSI still
  cannot tell CI from backups, media or cluster load, and every drain needs
  the recovery machinery that this replaces.
- **Freeze CI while a game runs.** Releases the CPU at once, but a frozen job
  cannot finish or be cancelled, which is the failure of 2026-10-31.
- **Cancel jobs at once when a game starts.** Frees the disk sooner, but
  cancels jobs that would have finished in seconds; most xyz jobs take about
  1.5 minutes, hence the 120-second drain.
- **A systemd `Conflicts=` between a game target and the runners.** Starting
  a runner would then stop the game target, so a switch or a manual start
  would end the hold.
- **Keep the standby controller for `ci-fast`.** With xyz holding its runners
  only during games, an always-on `xev-fast` serves fast jobs at least as well
  and needs no status endpoint.

## Consequences

- During a game on xyz, CI moves to xev, nex and nux; `ci-fast` jobs run on
  `xev-fast`. Wolf images do not publish and DMS does not update.
- A job running on xyz when a game starts finishes if it can within two
  minutes, and is cancelled otherwise; Forgejo shows it failed or cancelled,
  and it must be re-run. The same applies to a reboot or a Podman store reset on xyz,
  whose idle check avoids it.
- Without the pressure drain, CI on every host runs through unrelated load;
  only the slot counts and the slice's CPU and memory limits bound it.
- The disk floor is a hold, not a quota: running jobs keep writing.
- A runner the operator stops stays stopped; to keep a held runner off,
  disable or mask it.
- The VM check `forgejo-runner-hold-lifecycle` runs the hold with the
  production units: each kind of game, a gate refusing a start, a stop that
  times out during a game, an operator stop, a restarted controller and a lost
  signal. Unit tests cover the hold, the gate and the signal.

Supersedes the pressure guard, freeze, teardown boundary and hold monitor
parts of [ADR-0072](0072-isolated-runner-docker.md) and the standby of
[ADR-0097](0097-ci-fast-runner-label.md), whose replaced text is in their
history files. Tracks [#916](https://git.alc.xyz/alcxyz/nix-config/issues/916)
(step 4) and closes [#646](https://git.alc.xyz/alcxyz/nix-config/issues/646).
