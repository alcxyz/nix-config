# ADR-0105: Reset the Podman CI store offline while the runners are idle

**Status:** Accepted
**Date:** 2026-10-31
**Amended:** 2026-10-31, the runner hold of [ADR-0106](0106-runner-hold-for-games-and-low-disk.md) replaces the pressure guard's part, and runners are stopped only when idle; 2026-11-02, the retired CI Nix cache proxy no longer supplies Nix paths; 2026-11-05, xyz's store moves to ext4 ([#995](https://git.alc.xyz/alcxyz/nix-config/issues/995)); 2026-11-08, the store may keep its containers and volumes in RAM scratch ([ADR-0108](0108-ram-scratch-for-podman-ci-jobs.md)), and the reset clears both parts by age or disk use and the scratch alone when it fills; 2026-11-12, volumes on disk beside the store, which the API's start moves aside as trash ([ADR-0108](0108-ram-scratch-for-podman-ci-jobs.md)); 2026-11-12, leftover containers reset the scratch alone ([ADR-0108](0108-ram-scratch-for-podman-ci-jobs.md)); 2026-11-12, volumes in a filesystem on zram that the API's start makes afresh, whose use or failure also resets the scratch alone ([ADR-0108](0108-ram-scratch-for-podman-ci-jobs.md)); 2026-11-13, a full scratch or volume filesystem drains a running pool job instead of skipping for it
**History:** [replaced text](archive/0105-offline-podman-store-reset-history.md)
**Supersedes:** [ADR-0083](archive/0083-podman-cleanup-completion-fence.md)
**Applies to:** `modules/nixos/services/forgejo-actions-runner/podman-store-reset.{nix,sh}`,
the runner start gates and the runner hold, the runner pool on xyz, xev, nex and nux

## Context

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
cheap, Nix paths come from the public binary caches, and the cleanup already
deleted the Buildx state volumes in every idle window.

The runner (forgejo-runner v13.2.0 as built here) shuts down gracefully on
SIGTERM: it stops polling and waits for running jobs up to
`runner.shutdown_timeout` before it cancels them
(`internal/app/cmd/daemon.go` and `internal/app/poll/poller.go`; the local
patch does not touch this path). That timeout is 3600 seconds on xev, nex and
nux and 120 seconds on xyz ([ADR-0106](0106-runner-hold-for-games-and-low-disk.md)),
so a runner stop on xyz cancels a job that runs longer than two minutes.

## Decision

Replace the live cleanup by an offline reset of the whole Podman store. Every
runner host enables `services.forgejo-actions-runner.podmanStoreReset`. A timer
checks every 15 minutes, and a check changes nothing unless a reset is due and
the host is idle.

- **Due:** the last reset is at least 7 days old (`maxAgeDays`), or the
  filesystem holding the store is at least 70 percent used
  (`triggerUsedPercent`) and the last reset is at least six hours old, or the
  RAM scratch holding its containers, or the volume filesystem in RAM
  ([ADR-0108](0108-ram-scratch-for-podman-ci-jobs.md)), is used to the
  host's `scratchTriggerPercent` (70 percent by default, 25 on xev, nex and
  nux, 5 on xyz; the volume filesystem in bytes or in inodes, whichever is
  fuller, since inodes used up fail every new volume as a full filesystem
  does), or that volume filesystem is unusable, or the Podman API
  with that scratch holds any container other than a running
  `FORGEJO-ACTIONS-TASK-*` one. The volume filesystem counts only while the
  running API uses it: the API start that made it writes its systemd
  invocation ID to `/run/forgejo-podman-volumes.started`, and while that
  does not match the API's, as after a deploy that has not restarted it,
  the check logs `volumes=not_in_use` and ignores the filesystem; while
  it does use it, each check also compacts the filesystem's zram device. It
  is unusable when not mounted, when another filesystem is mounted there,
  when the mount or its superblock is read-only, or when ext4's error count
  (`/sys/fs/ext4/<device>/errors_count`), zero on the fresh filesystem, is
  not: under `errors=remount-ro` an ext4 error stops every write, but on
  the hosts' kernel, 7.3.3 in the VM check, `mountinfo` still shows the
  mount and its superblock `rw`, the superblock with `emergency_ro`. A
  failed write of file data is no ext4 error, and the check does not see
  it (ADR-0108). A full scratch or volume filesystem, like
  such a container, means containers or volumes that jobs left behind; that
  reset renames only the scratch part, its API start makes the volume
  filesystem afresh, and it keeps the images and the age clock, and since it
  always empties the scratch it needs no minimum age. The first run only
  starts the age clock,
  kept in the unit's root-owned state directory.
- **Idle:** the game signal reports no game (on a game host) and host I/O
  pressure is at or below `ioPressurePercent` (5 percent); the runner hold is
  active and every runner has its hold state directory; no Docker cache prune
  runs; both APIs are active; every runner is either running with no pending
  systemd job, or stopped by whoever stopped it; neither API runs a
  `FORGEJO-ACTIONS-TASK-*` container; and no runner to be stopped has logged a
  job start in the last `quietMinutes` (15 minutes), since a job that is still
  pulling its image or setting up has no task container yet. A scratch or
  volume filesystem at 90 percent or more (of its bytes or its inodes), or
  an unusable volume filesystem,
  is the recovery threshold: most new pool jobs fail there,
  and each would renew that interval, while a pool job that is still
  running would skip every check that finds it, so neither a recent pool
  job start nor a running Podman task container skips the reset. Instead
  the reset pauses the running Podman pool runners (both slots on xyz)
  through the runner pause of nix-packages ADR-0017 (no new job) and waits,
  up to 10 minutes for all of them together, for each to report none
  running and then for the Podman API to run no task container, since a
  runner reports its job done before the job's container is gone. It checks
  the pause and the report again right before each runner's stop, since a
  runner restart removes every pause when it ends. If the wait runs out, or
  either check fails, it removes its pauses and skips, and the next check,
  15 minutes after this one started, tries again: a job that runs longer
  keeps the pool paused for at most 10 minutes of each check while the
  filesystem stays full. A Podman task container that no running pool
  runner can drain still skips the reset. A pause someone else set skips the
  reset; the reset removes its own pause once the runner is stopped, and its
  `ExecStopPost` removes it on any other exit. The Docker
  runner, whose jobs use their own store, keeps the quiet interval, and a
  task container on its API skips the reset. A reset stops no
  runner with a job it can see: on xyz the stop would cancel it after two
  minutes. A job still pulling its image more than 15 minutes after it
  started shows neither sign and remains a gap.
- **Stop:** record the APIs and the running runners in a runtime list, then
  stop the runners one at a time, checking right before each stop that
  neither API runs a task container and that the runner has logged no recent
  job start. A job admitted between that check and the stop is the one window
  left. Then check again that the runner hold is
  active and every runner is stopped (the hold may have released one
  meanwhile), and stop both APIs (an ordinary graceful stop).
- **Rename:** under the start lock, which every runner and API start gate
  takes first, prove every runner and both APIs stopped with no pending job and
  empty API cgroups, and that nothing is mounted at or below the store. Then
  rename the store directory to a hidden trash name beside it, on the same
  filesystem: a directory inside the mount, never a mount itself. With RAM
  scratch the store has two directories, the image store on disk and the
  graphroot in the scratch tmpfs, whose containers reference the image
  layers; both are renamed, the graphroot first, so a crash between the two
  leaves an empty graphroot beside an intact image store. A reset for a full
  scratch renames only the graphroot. On xyz the
  store is a directory in a bind mount from `/ext4` at
  `/var/lib/forgejo-podman`, on xev a directory on a dedicated ext4 partition
  mounted there, and on nex and nux a directory on the root filesystem. Sync the rename and the age stamp, then release the lock.
- **Start:** start both APIs at once, and with them only the runners the reset
  stopped. The start gates still decide each start. A runner whose gate refuses
  the start (for a game that began meanwhile, say) keeps the gate's `held`
  marker, and the runner hold starts it once its hold reason ends. Every
  runner host runs the hold.
- **Delete:** the scratch part of the old store is deleted right after the
  rename, before anything starts again: it is RAM that a full scratch would
  deny the API's own start, and deleting it writes no disk. Remove the rest
  of the old store at the lowest CPU and I/O priority, through
  a descriptor opened on it so the API user cannot redirect the removal. Stop
  while a game is detected, pressure rises above `ioPressurePercent` or 30
  minutes pass. Leftover trash is garbage that the next check deletes first; a
  due reset waits until it is gone, except a reset of the scratch alone, which
  touches no disk. The API user can create entries with the
  trash name: one that is not a directory is unlinked without being followed,
  and one that fails the checks or cannot be removed is reported and skipped,
  so neither stops or holds a reset. With RAM scratch the volumes' metadata
  goes with the API's runroot. With the volumes in RAM, the API's start
  makes their filesystem afresh, which frees their memory; with them on
  disk beside the store, and once when they move to RAM, it moves a
  non-empty volume directory aside under the store's trash name, and the
  reset deletes it like the rest of the old store.

The rename is the only mutation that needs exclusion, and it cannot outlive the
process that holds the lock, so no completion fence exists. The lock is
`/run/forgejo-runner-hold/start.lock`. The unit's
`ExecStopPost` starts every unit on the runtime list in the same way, so a
failed, skipped or killed run leaves no runner stopped without an owner. After a reboot the store is
either the old one, unchanged, or a new empty one; the boot needs no recovery
step. No systemd `Conflicts=` or ordering dependency excludes the reset: a start
of a conflicting unit would stop it mid-run.

The runner hold's left-off check treats a runner on the reset's runtime list
as an intended hold while the reset runs. A completion fence left from before
this decision, in `/run/forgejo-runner-aggregate-pressure`, blocks nothing:
the gates and the hold ignore it, and the next check resets the store at once
and removes it.

The dedicated Docker daemon keeps its own retention
([ADR-0072](0072-isolated-runner-docker.md)): native BuildKit GC and the daily
and pressure prunes run inside Docker, which completes its own deletions. Its
volumes are never swept automatically; when one must go, an operator removes it
with Docker's own CLI in a maintenance window with the runners stopped. The
manual Docker volume mode of the old cleanup is retired with the fences.

## Alternatives Considered

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
  queued jobs; the start lock already orders every start gate.

## Consequences

A reset costs CI about 3 to 4 seconds of downtime in the VM test, plus the time
any running job needs to finish. Jobs after a reset pull their images again,
through the LAN cache, and rebuild BuildKit state. Between resets nothing is
deleted from the store, so it grows until the next reset; the disk floor of
[ADR-0106](0106-runner-hold-for-games-and-low-disk.md) still applies, and a
disk hold is an idle window in which a reset can run. On a
host whose root filesystem is mostly other data, the use trigger can reset at
most every six hours.

The VM check `forgejo-podman-store-reset-lifecycle` runs the reset with both
production API units: a due reset, an API start waiting on the lock and
preventing the rename, a run killed while it holds the lock, a crash after the
rename, and a leftover fence. Unit tests cover the skip matrix, a job that
appears between runner stops, the restart list and the bounded trash deletion.

Tracks [#916](https://git.alc.xyz/alcxyz/nix-config/issues/916) (step 2).
