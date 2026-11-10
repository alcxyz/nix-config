# ADR-0108: Keep Podman CI job scratch in RAM, images on disk

**Status:** Accepted
**Date:** 2026-11-08
**Amended:** 2026-11-10, a second pool slot on xyz sharing a 24G scratch ([#1027](https://git.alc.xyz/alcxyz/nix-config/issues/1027))
**History:** [replaced text](archive/0108-ram-scratch-for-podman-ci-jobs-history.md)
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

- **One tmpfs per host.** The tmpfs `size` is a per-host option, and every
  pool slot on a host shares it. xev, nex and nux run one pool slot
  ([ADR-0106](0106-runner-hold-for-games-and-low-disk.md)), so their 8G is
  that job's limit. xyz runs two, which share 24G: 16G for a
  `forgejo-podman-large` job, which only its first slot takes, and 8G for a
  pool job, the other hosts' limit. A job that writes past the free space
  fails with "No space left on device". The tmpfs cannot give each job its
  own limit, since every job container writes as the same user, so a pool
  job that writes more than 8G on xyz takes room from the other slot's job,
  which may then fail the same way; such a job already fails on the other
  three hosts. The Docker slot uses its own store and no scratch.
- **Memory.** tmpfs pages are charged to the cgroup that writes them, here
  `forgejobuilds.slice`, which also holds the Docker slot's job. The tmpfs is
  mounted `noswap`, so scratch never reaches the swap disks: under memory
  pressure the slice is throttled at memoryHigh or OOM-killed at memoryMax,
  inside its own budget. Each host's throttle holds its full scratch beside
  a memory budget for each pool job, so a full scratch fails a write before
  the slice is throttled while the jobs keep to those budgets. Nothing
  limits a single job's memory, so a job beyond its budget, or a Docker job
  beside full pool slots, can reach the throttle first; the hard limit still
  bounds the slice. On the 31 GiB xev, nex and nux it is 45%, with a 50%
  hard limit (about 14.0 and 15.6 GiB), since their cluster comes first:
  about 15.6 GiB stays for the cluster services, which used 7 to 11G in
  November 2026, and 8G of scratch leaves about 6 GiB under the throttle for
  the job. On the 62.3 GiB xyz it is 64%, with a 69% hard limit (39.9 and
  43.0 GiB): the 24G scratch, two pool jobs' 6 GiB each, as on the other
  hosts (a large job, in the first slot only, takes 4.5 GiB, the 4.8 GB
  measured), and the 3G cap of the shared Nix store's filler, which also
  runs in the slice with 1G of staging
  ([ADR-0109](0109-shared-read-only-nix-store-for-podman-ci-jobs.md)), leave
  0.9 GiB for the engines, which idled at 0.1 to 0.2 GiB in November 2026,
  and the rarely used Docker job. The filler stages
  an input only when it finds no job running, so it meets full jobs only
  for one input. The hard limit leaves 19.3 GiB for
  the desktop (about 14 GiB in November 2026), the services and the ZFS ARC,
  which shrinks under pressure to 2 GiB. A game holds the runners and
  cancels their jobs after a two-minute grace
  ([ADR-0106](0106-runner-hold-for-games-and-low-disk.md)), so a game meets
  a full CI slice for at most those minutes and the cleanup after.
  The nix-daemon's 40G cap sits beside the CI limit, so a large deploy build
  that meets a full CI slice can still overcommit the host.
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
  default, 13 percent (3.1G) on xyz so a 12.8G large job and an 8G pool job
  still fit its 24G. At 90 percent,
  the recovery threshold, most new pool jobs fail, so the reset then pauses
  the pool runners and waits for them to drain instead of waiting out their
  quiet interval,
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
  only xyz's first pool slot serves, one at a time: the nix-packages Nix
  update jobs (`update-t3code.yml` and `update-packages.yml`), one of which
  kept 12.7G live. Such a job with its
  4.8G of memory would need about 20G of CI memory on a 31 GiB cluster node,
  more than its other services leave. These jobs wait while xyz is held for a
  game or off.

The Docker runner's store is unchanged: it serves the few jobs that still
select a Docker label.

## Alternatives Considered

- **One pool slot on every host**, xyz included: each tmpfs is one job's
  limit, but a replay of the pool's November arrivals put the busy-hour p90
  queue wait at 26 minutes with four slots in all, against 3.5 with six.
  xyz's second slot makes five, which the replay puts near 5.5 minutes.
- **One Podman store per slot**, each with its own tmpfs: a per-job limit
  with two slots, but one API, socket and store per slot, and changes to the
  reset, the start gates and their tests.
- **A second slot through `capacity = 2`** on one runner, as xyz ran before
  the scratch: one registration, but both slots would serve
  `forgejo-podman-large`, and two large jobs of up to 12.8G each would
  overrun the scratch.
- **A shared, cached Nix store per host** for the Nix jobs, which would cut
  most of their writes without RAM, but shares one readable store across all
  jobs and needs garbage collection and a change to every Nix workflow; a
  follow-up, now [ADR-0109](0109-shared-read-only-nix-store-for-podman-ci-jobs.md).
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
clearly instead of slowing the host. On xyz, with two slots, the store
reset and the shared Nix store's filler
([ADR-0109](0109-shared-read-only-nix-store-for-podman-ci-jobs.md)) find
fewer moments with no job running, so a due reset and the filler's
additions wait longer. A reboot or an unmounted tmpfs loses
running containers and volumes, as a reset does, and keeps the images.

The API has `restartIfChanged = false`, so enabling or disabling scratch
takes effect at the next API restart (`runners restart` while idle) or reboot;
the deploy itself stops nothing. After disabling it, the tmpfs stays mounted
(`X-StopOnRemoval = false`) until it is unmounted once the API runs on the disk
store, or until the next reboot. A smaller `size` takes effect when the
switch remounts the tmpfs, which fails while more is in use; the tmpfs then
keeps its old size, which the new memory limits may not hold, until a
`systemctl reload` of its mount unit once it is emptied (`runners restart`
empties it but does not remount it) or the next reboot. Shrink it while the
runners are idle.

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
