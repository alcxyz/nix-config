**History of** [ADR-0105](../0105-offline-podman-store-reset.md): text replaced on 2026-10-31.

## Text replaced on 2026-10-31 (ADR-0106)

The ADR as it stood before the runner hold of [ADR-0106](../0106-runner-hold-for-games-and-low-disk.md) replaced the pressure guard, its freeze and teardown boundary, the `ci-fast` standby and the hold monitor ([#916](https://git.alc.xyz/alcxyz/nix-config/issues/916)).

## ADR-0105: Reset the Podman CI store offline while the runners are idle

**Status:** Accepted
**Date:** 2026-10-31
**Supersedes:** [ADR-0083](0083-podman-cleanup-completion-fence.md)
**Applies to:** `modules/nixos/services/forgejo-actions-runner/podman-store-reset.{nix,sh}`,
the runner start gates and hold monitor, the runner pool on xyz, xev, nex and nux

### Context

The dedicated rootless Podman API keeps the CI image, container and volume
store of the Podman runner pool. Until now an idle cleanup deleted old images,
leftover containers and Buildx state volumes through that live API, one request
at a time. A client deadline does not bound a server-side storage deletion in
Podman 5.8.7, so ADR-0083 fenced admission until completion was proven, and two
recovery commands, one manual and one on a timer (#914), cleared the fences.
On xyz in October 2026 two exited-container removals outlived their client and
kept the runners offline for about 75 and 120 minutes. The fence and recovery
states came from mutating storage through a live API, not from the store
itself, which is disposable: the LAN registry cache (#917) makes re-pulls
cheap, Nix paths come through the CI cache proxy
([ADR-0103](../0103-ci-nix-cache-proxy.md)), and the cleanup already deleted the
Buildx state volumes in every idle window.

The runner (forgejo-runner v13.2.0 as built here) shuts down gracefully on
SIGTERM: it stops polling and waits for running jobs up to
`runner.shutdown_timeout` (3600 seconds here, as long as the job timeout)
before it cancels them (`internal/app/cmd/daemon.go` and
`internal/app/poll/poller.go`; the local patch does not touch this path). So a
runner stop never kills a job the runner already admitted; it only waits for it.

### Decision

Replace the live cleanup by an offline reset of the whole Podman store. Every
runner host enables `services.forgejo-actions-runner.podmanStoreReset`. A timer
checks every 15 minutes, and a check changes nothing unless a reset is due and
the host is idle.

- **Due:** the last reset is at least 7 days old (`maxAgeDays`), or the
  filesystem holding the store is at least 70 percent used
  (`triggerUsedPercent`) and the last reset is at least six hours old. The
  first run only starts the age clock, kept in the unit's root-owned state
  directory.
- **Idle:** no game is detected and host I/O pressure is at or below the
  guard's resume threshold; the guard is active and the build aggregate is not
  frozen; the guard's runner registry matches the configured runner list (after
  a switch that changed the list, the start gates refuse every start until a
  reboot clears the preserved registry; a guard restart alone refuses the
  changed list); no guard transition marker is present; no Docker cache prune runs;
  both APIs are active; every runner is either running with no pending systemd
  job, or stopped by whoever stopped it; and neither API runs a
  `FORGEJO-ACTIONS-TASK-*` container. This check only keeps the stop short. A
  job admitted after it still finishes, because the runner's shutdown waits.
- **Stop:** record the APIs and the running runners in a runtime list, stop
  those runners, check again that the aggregate is not frozen, the guard is
  active and every runner is stopped (a standby controller or a guard resume
  may have started one meanwhile), then stop both APIs (an ordinary graceful
  lifecycle stop).
- **Rename:** under the lifecycle lock, which every runner and API start gate
  takes first, prove every runner and both APIs stopped with no pending job and
  empty API cgroups, and that nothing is mounted at or below the store. Then
  rename the store directory to a hidden trash name beside it, on the same
  filesystem: a directory inside the mount, never a mount itself. On xyz the
  store is a directory in the `forgejo-podman` ZFS dataset mounted at
  `/var/lib/forgejo-podman`; on xev, nex and nux it is a directory on the root
  filesystem. Sync the rename and the age stamp, then release the lock.
- **Start:** start both APIs at once, and with them only the runners the reset
  stopped. The start gates still decide each start. A runner whose gate refuses
  the start (for a freeze or a guard transition, say) gets a
  `reset-start-skipped` hold marker, and the pressure guard resumes it through
  its normal resume path, as for disk and game skips, once its conditions
  allow. This needs the guard's admission control, which every runner host
  enables.
- **Delete:** remove the old store at the lowest CPU and I/O priority, through
  a descriptor opened on it so the API user cannot redirect the removal. Stop
  while a game is detected, pressure rises above the resume threshold or 30
  minutes pass. Leftover trash is garbage that the next check deletes first; a
  due reset waits until it is gone. The API user can create entries with the
  trash name: one that is not a directory is unlinked without being followed,
  and one that fails the checks or cannot be removed is reported and skipped,
  so neither stops or holds a reset.

The rename is the only mutation that needs exclusion, and it cannot outlive the
process that holds the lock, so no completion fence exists. The unit's
`ExecStopPost` starts every unit on the runtime list in the same way, so a
failed, skipped or killed run leaves no runner stopped without an owner. After a reboot the store is
either the old one, unchanged, or a new empty one; the boot needs no recovery
step. No systemd `Conflicts=` or ordering dependency excludes the reset: a start
of a conflicting unit would stop it mid-run.

The hold monitor treats a runner on the reset's runtime list as an intended
hold while the reset runs, so a job that finishes before its runner stops (up
to an hour) does not report the other stopped runners. A completion fence left
from before this decision blocks nothing: the gates, guard and hold monitor
ignore it, and the next check resets the store at once and removes it.

The dedicated Docker daemon keeps its own retention
([ADR-0072](../0072-isolated-runner-docker.md)): native BuildKit GC and the daily
and pressure prunes run inside Docker, which completes its own deletions. Its
volumes are never swept automatically; when one must go, an operator removes it
with Docker's own CLI in a maintenance window with the runners stopped. The
manual Docker volume mode of the old cleanup is retired with the fences.

### Alternatives Considered

- Keep the fences and their automatic recovery (#915): sound, but it keeps the
  largest part of the runner guards (about 4,600 lines with their tests) and
  states that only exist because storage was mutated through a live API.
- Prune offline with the Podman CLI against the stopped store: also safe for
  exclusion, but it changes the store in place, so an interrupted prune leaves
  a partly changed store, and it needs the builder account's Podman
  environment. A reset is less code; beyond what the cleanup deleted, it loses
  only recent images, which the LAN cache serves again.
- Delete the store before starting the APIs again: shorter code path, but the
  runners stay stopped for the whole deletion (about 2 seconds for 100,000 files and
  1 GiB in the VM test, longer for a real store of tens of GiB).
- Order the units with `Conflicts=` or `After=` against the reset: a start of a
  conflicting unit would stop the reset mid-run, and ordering only applies to
  queued jobs; the lifecycle lock already orders every start gate.
- Drain the runners through the I/O pressure guard first: couples the reset to
  the drain states that a later step of #916 removes.

### Consequences

A reset costs CI about 3 to 4 seconds of downtime in the VM test, plus the time
any running job needs to finish. Jobs after a reset pull their images again,
through the LAN cache, and rebuild BuildKit state. Between resets nothing is
deleted from the store, so it grows until the next reset; the disk-space
admission and critical floors of [ADR-0072](../0072-isolated-runner-docker.md)
still apply, and a disk drain is an idle window in which a reset can run. On a
host whose root filesystem is mostly other data, the use trigger can reset at
most every six hours.

The VM check `forgejo-podman-store-reset-lifecycle` runs the reset with both
production API units: a due reset, an API start waiting on the lock and
preventing the rename, a run killed while it holds the lock, a crash after the
rename, and a leftover fence. Unit tests cover the skip matrix, the restart list
and the bounded trash deletion.

Tracks [#916](https://git.alc.xyz/alcxyz/nix-config/issues/916) (step 2).
