# ADR-0108: Keep Podman CI job scratch in RAM, images on disk

**Status:** Accepted
**Date:** 2026-11-08
**Applies to:** `modules/nixos/services/forgejo-actions-runner/podman-canary.nix`,
`podman-scratch-prepare.sh`, the store reset of
[ADR-0105](0105-offline-podman-store-reset.md), the runner pool on xyz, xev,
nex and nux

## Context

The Podman CI stores wrote about 270 to 325 GB a day to consumer SATA SSDs on
xyz and xev in November 2026, enough to reach their rated write endurance in
about a year on xyz and possibly months on xev
([#1027](https://git.alc.xyz/alcxyz/nix-config/issues/1027)). A kernel trace
of ext4 writeback on both CI disks attributed nearly all of it to data that
lives only for one job: the job container's writable layer (apt installs,
Nix installed into the container and its store filled from the public
caches), the workspace volume, and nested containers that jobs start through
the API socket (Go builds and tests, postgres initdb and its fsyncs). Overlay
copy-ups were negligible. Image pulls and `buildx --load` imports were a small
share. One Nix-heavy job, the T3 nightly update check, wrote 15 GB in one run,
with 12.7 GB live at its peak and 4.8 GB of process memory.

All four runner hosts keep the CI store on ext4 and stay alike. Earlier
decisions on the runners ([#916](https://git.alc.xyz/alcxyz/nix-config/issues/916),
[#897](https://git.alc.xyz/alcxyz/nix-config/issues/897), [#917](https://git.alc.xyz/alcxyz/nix-config/issues/917))
weighed job time, stalls and registry limits, not SSD wear.

Podman 6.1.4's storage library splits a store when `imagestore` is set:
read-only layers, which are image layers whether pulled, loaded or built, and
the image and image-layer metadata go to the image store; container layers,
their metadata, the libpod database and, by default, volumes stay under the
graphroot (`go.podman.io/storage` `drivers/overlay` `dir2`, `store.go`,
`layers.go` `pickStoreLocation`). Wiping the graphroot leaves a consistent
image store.

## Decision

`services.forgejo-actions-runner.podmanCanary.scratch` puts the Podman API's
graphroot in a tmpfs at `/run/forgejo-podman-scratch` (`--root`), and keeps
the existing disk store at `/var/lib/forgejo-podman/storage` as its image
store (`--imagestore`). Container writable layers, copy-ups and every volume
(job workspaces, service data, Buildx state) are in RAM; image layers stay on
disk and survive reboots.

- **Metadata outside the scratch.** The API runs a transient store
  (`--transient-store`): the libpod database and the container and volume
  metadata live in the runroot under `/run/forgejo-podman`, not in the
  size-limited tmpfs. A job that fills the scratch fails only its own data
  writes; the API still records, lists and removes containers. Without it,
  the VM check showed the database failing with "database or disk is full"
  for every job once one job had filled the scratch.

- **One job per tmpfs.** Every host's Podman pool runner takes one job
  ([ADR-0106](0106-runner-hold-for-games-and-low-disk.md)), so the tmpfs,
  whose `size` is a per-host option, is that job's limit: 16G on xyz and 8G
  on xev, nex and nux. A job that writes past it fails with "No space left on
  device". The Docker slot uses its own store and no scratch.
- **Memory.** tmpfs pages are charged to the cgroup that writes them, here
  `forgejobuilds.slice`, which also holds the Docker slot's job. The tmpfs is
  mounted `noswap`, so scratch never reaches the swap disks: under memory
  pressure the slice is throttled at memoryHigh or OOM-killed at memoryMax,
  inside its own budget. Each host's limits hold its scratch beside the pool
  job and the rarely used Docker job: 40% and 45% on
  xyz (about 24.9 and 28G of 62G), and 45% and 50% on the 31 GiB xev, nex
  and nux (about 14.0 and 15.6G), since their cluster comes first: about
  15.6G stays for the cluster services, which used 7 to 11G in November
  2026, and 8G of scratch leaves about 6G under the throttle for the jobs. On xyz the
  nix-daemon's 40G cap and the ARC sit beside the CI limit, so a large deploy
  build that meets a full CI slice can still overcommit the host.
- **Never on disk by accident.** The API starts after the tmpfs mount
  (`WantsMountsFor`), and its root `ExecStartPre` refuses to start unless a
  tmpfs is mounted there. The dependency is only a want, so a deploy that
  adds or removes the mount never stops a running API and its job.
  The tmpfs is not one of the runner hold's disk-floor paths
  ([ADR-0106](0106-runner-hold-for-games-and-low-disk.md)).
- **Leftovers.** systemd removes the runroot whenever the API stops, so the
  tmpfs holds nothing an API start can still reference: the API's root
  `ExecStartPre` empties all of it, trash from an interrupted reset included.
  Containers and volumes that jobs leave behind while the API runs fill the
  scratch; the store reset clears the scratch alone, keeping the images, at
  any age once it reaches the host's `scratchTriggerPercent`: 70 percent by
  default, 20 percent on xyz so a 12.8G job still fits its 16G. At 90 percent,
  the recovery threshold, most new pool jobs fail, so the reset then pauses
  the pool runner and waits for it to drain instead of waiting out its quiet
  interval,
  whatever made it due; the Docker runner keeps the interval, and a running
  task container on either engine still holds the reset. Its age
  and disk triggers clear the graphroot and the image store together. Either
  way it frees the scratch before the API starts again
  ([ADR-0105](0105-offline-podman-store-reset.md)).
- **Switching.** The first start with scratch moves a disk store that still
  holds containers (a graphroot from before) aside under the reset's trash
  name; the reset's next check deletes it, and images are pulled again once
  through the LAN cache. Turning scratch off uses the image store as the
  graphroot again, which needs no migration.
- **Jobs larger than 8G of scratch** select `forgejo-podman-large`, which
  only xyz's pool runner serves: the nix-packages Nix update jobs
  (`update-t3code.yml` and `update-packages.yml`), one of which kept 12.7G
  live. Such a job with its 4.8G of memory would need about 20G of CI memory
  on a 31 GiB cluster node, more than its other services leave. These jobs
  wait while xyz is held for a game or off.

The Docker runner's store is unchanged: it serves the few jobs that still
select a Docker label.

## Alternatives Considered

- **Two pool slots sharing one tmpfs**: more throughput (a replay of the
  pool's November arrivals put the busy-hour p90 queue wait at 26 minutes
  with four slots in all and 3.5 with six), but one job could use up the
  other's scratch. A fifth slot on xps is to recover most of the wait; xev
  back to two slots is the fallback.
- **One Podman store per slot**, each with its own tmpfs: a per-job limit
  with two slots, but one API, socket and store per slot, and changes to the
  reset, the start gates and their tests.
- **A shared, cached Nix store per host** for the Nix jobs, which would cut
  most of their writes without RAM, but shares one readable store across all
  jobs and needs garbage collection and a change to every Nix workflow; a
  follow-up.
- **The whole store in RAM**: simpler, but images would be pulled and
  extracted again after every reboot and would take RAM.
- **zram or a block device in RAM under the store**: compression would fit
  more, but its memory is not charged to the CI slice, and a full device
  fails writes with I/O errors that ext4 turns into a read-only filesystem
  rather than "disk full".
- **Writeback tuning or ext4 options**: longer dirty expiry or commit
  intervals would keep some short-lived files off the disk, but are global,
  risk data on other filesystems, and leave longer-lived job data on the SSD.
- **ZFS with compression and block cloning**: rejected by the owner; the
  runner hosts stay alike on ext4.

## Consequences

CI SSD writes are expected to fall by about 90 percent, to image pulls,
image imports and filesystem metadata. Jobs spend less time waiting on the
SATA disks. The hosts give the tmpfs size, at most, of RAM to CI on top of
the jobs' own memory; the sizes and memory limits are per host in its
configuration. A job that needs more scratch than its host offers fails
clearly instead of slowing the host. A reboot or an unmounted tmpfs loses
running containers and volumes, as a reset does, and keeps the images.

The API has `restartIfChanged = false`, so enabling or disabling scratch
takes effect at the next API restart (`runners restart` while idle) or reboot;
the deploy itself stops nothing. After disabling it, the tmpfs stays mounted
(`X-StopOnRemoval = false`) until it is unmounted once the API runs on the disk
store, or until the next reboot.

The VM check `forgejo-podman-scratch-lifecycle` runs the production API with
a 256M scratch: image layers on disk and container data in RAM charged to the
slice, an oversized write that fails with "No space left on device" while
the slice reaches no memory.high event and the API keeps serving another
job's container, an API restart that empties the scratch, a fresh tmpfs that
keeps the images,
the API refusing to start without the tmpfs, the migration of an old store,
a reset by age that clears both parts, a scratch filled to the last byte that
resets alone and keeps the images, and deploys that turn scratch off and on
under a running API.
