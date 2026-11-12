**History of** [ADR-0108](../0108-ram-scratch-for-podman-ci-jobs.md): text replaced on 2026-11-10, 2026-11-11 and 2026-11-12 (twice).

## Text replaced on 2026-11-10 (#1027)

The text as it stood before xyz took a second pool slot sharing a 24G scratch ([#1027](https://git.alc.xyz/alcxyz/nix-config/issues/1027)).

> - **One job per tmpfs.** Every host's Podman pool runner takes one job
>   ([ADR-0106](../0106-runner-hold-for-games-and-low-disk.md)), so the tmpfs,
>   whose `size` is a per-host option, is that job's limit: 16G on xyz and 8G
>   on xev, nex and nux. A job that writes past it fails with "No space left on
>   device". The Docker slot uses its own store and no scratch.

>   pressure the slice is throttled at memoryHigh or OOM-killed at memoryMax,
>   inside its own budget. Each host's limits hold its scratch beside the pool
>   job and the rarely used Docker job: 40% and 45% on
>   xyz (about 24.9 and 28G of 62G), and 45% and 50% on the 31 GiB xev, nex
>   and nux (about 14.0 and 15.6G), since their cluster comes first: about
>   15.6G stays for the cluster services, which used 7 to 11G in November
>   2026, and 8G of scratch leaves about 6G under the throttle for the jobs. On xyz the
>   nix-daemon's 40G cap and the ARC sit beside the CI limit, so a large deploy
>   build that meets a full CI slice can still overcommit the host.

>   any age once it reaches the host's `scratchTriggerPercent`: 70 percent by
>   default, 20 percent on xyz so a 12.8G job still fits its 16G. At 90 percent,
>   the recovery threshold, most new pool jobs fail, so the reset then pauses
>   the pool runner and waits for it to drain instead of waiting out its quiet
>   interval,
>   whatever made it due; the Docker runner keeps the interval, and a running
>   task container on either engine still holds the reset.

> - **Jobs larger than 8G of scratch** select `forgejo-podman-large`, which
>   only xyz's pool runner serves: the nix-packages Nix update jobs
>   (`update-t3code.yml` and `update-packages.yml`), one of which kept 12.7G
>   live. Such a job with its 4.8G of memory would need about 20G of CI memory
>   on a 31 GiB cluster node, more than its other services leave. These jobs
>   wait while xyz is held for a game or off.

> - **Two pool slots sharing one tmpfs**: more throughput (a replay of the
>   pool's November arrivals put the busy-hour p90 queue wait at 26 minutes
>   with four slots in all and 3.5 with six), but one job could use up the
>   other's scratch. A fifth slot on xps is to recover most of the wait; xev
>   back to two slots is the fallback.
> - **One Podman store per slot**, each with its own tmpfs: a per-job limit
>   with two slots, but one API, socket and store per slot, and changes to the
>   reset, the start gates and their tests.

> CI SSD writes are expected to fall by about 90 percent, to image pulls,
> image imports and filesystem metadata. Jobs spend less time waiting on the
> SATA disks. The hosts give the tmpfs size, at most, of RAM to CI on top of
> the jobs' own memory; the sizes and memory limits are per host in its
> configuration. A job that needs more scratch than its host offers fails
> clearly instead of slowing the host.

## Text replaced on 2026-11-11 (shared memory budget on xyz)

The text as it stood before the nix-daemon and CI on xyz shared one memory
budget in `forgejobuilds.slice`.

> - **Memory.** tmpfs pages are charged to the cgroup that writes them, here
>   `forgejobuilds.slice`, which also holds the Docker slot's job. The tmpfs is
>   mounted `noswap`, so scratch never reaches the swap disks: under memory
>   pressure the slice is throttled at memoryHigh or OOM-killed at memoryMax,
>   inside its own budget.

>   the job. On the 62.3 GiB xyz it is 64%, with a 69% hard limit (39.9 and
>   43.0 GiB): the 24G scratch, two pool jobs' 6 GiB each, as on the other
>   hosts (a large job, in the first slot only, takes 4.5 GiB, the 4.8 GB
>   measured), and the 3G cap of the shared Nix store's filler, which also
>   runs in the slice with 1G of staging
>   ([ADR-0109](../0109-shared-read-only-nix-store-for-podman-ci-jobs.md)), leave
>   0.9 GiB for the engines, which idled at 0.1 to 0.2 GiB in November 2026,
>   and the rarely used Docker job. The filler stages
>   an input only when it finds no job running, so it meets full jobs only
>   for one input. The hard limit leaves 19.3 GiB for
>   the desktop (about 14 GiB in November 2026), the services and the ZFS ARC,
>   which shrinks under pressure to 2 GiB. A game holds the runners and
>   cancels their jobs after a two-minute grace
>   ([ADR-0106](../0106-runner-hold-for-games-and-low-disk.md)), so a game meets
>   a full CI slice for at most those minutes and the cleanup after.
>   The nix-daemon's 40G cap sits beside the CI limit, so a large deploy build
>   that meets a full CI slice can still overcommit the host.

## Text replaced on 2026-11-12 (volumes on disk)

The text as it stood before the volumes moved out of the scratch to the disk
beside the image store, since BuildKit builds that run dpkg failed with
their state on tmpfs.

> # ADR-0108: Keep Podman CI job scratch in RAM, images on disk

> the existing disk store at `/var/lib/forgejo-podman/storage` as its image
> store (`--imagestore`). Container writable layers, copy-ups and every volume
> (job workspaces, service data, Buildx state) are in RAM; image layers stay on
> disk and survive reboots.

>   Containers and volumes that jobs leave behind while the API runs fill the
>   scratch; the store reset clears the scratch alone, keeping the images, at

>   through the LAN cache. Turning scratch off uses the image store as the
>   graphroot again, which needs no migration.

> CI SSD writes are expected to fall by about 90 percent, to image pulls,
> image imports and filesystem metadata. Jobs spend less time waiting on the

> a 256M scratch: image layers on disk and container data in RAM charged to the
> slice, an oversized write that fails with "No space left on device" while
> the slice reaches no memory.high event and the API keeps serving another
> job's container, an API restart that empties the scratch, a fresh tmpfs that
> keeps the images,

## Text replaced on 2026-11-12 (volumes in zram)

The passages as they stood before the volumes moved from the disk beside the
image store to an ext4 filesystem on zram, set aside from CI's memory, with
the tmpfs and CI's limits shrunk by its size.

> # ADR-0108: Keep Podman CI job scratch in RAM, images and volumes on disk

> **Amended:** 2026-11-10, a second pool slot on xyz sharing a 24G scratch ([#1027](https://git.alc.xyz/alcxyz/nix-config/issues/1027)); 2026-11-11, one memory budget for the nix-daemon and CI on xyz; 2026-11-12, volumes on disk beside the image store, since BuildKit builds that run dpkg failed with their state on tmpfs; 2026-11-12, any container that no running job owns resets the scratch at the next quiet check

> `podman-scratch-prepare.sh`, the runner module's `resourcePolicy`, the store reset of

> with it on disk, the graphroot still on tmpfs.

> store (`--imagestore`). Volumes (job workspaces, service data, Buildx state)
> are in `/var/lib/forgejo-podman/volumes` beside it (`--volumepath`).
> Container writable layers and copy-ups are in RAM; image layers and volumes
> are on disk, and image layers survive reboots.

> - **Volumes on disk.** BuildKit's state is a volume, and on tmpfs its builds
>   that run dpkg fail (see Context). Podman places volumes by one path for
>   all, and buildx creates the state volume itself, without options, so the
>   volumes leave the scratch together. The volume directory is on the store's
>   filesystem, whose use the store reset's disk trigger already measures.

> - **One tmpfs per host.** The tmpfs `size` is a per-host option, and every
>   pool slot on a host shares it. xev, nex and nux run one pool slot
>   ([ADR-0106](../0106-runner-hold-for-games-and-low-disk.md)), so their 8G is
>   that job's limit. xyz runs two, which share 24G: 16G for a
>   `forgejo-podman-large` job, which only its first slot takes, and 8G for a
>   pool job, the other hosts' limit. A job that writes past the free space
>   fails with "No space left on device". The tmpfs cannot give each job its
>   own limit, since every job container writes as the same user, so a pool
>   job that writes more than 8G on xyz takes room from the other slot's job,
>   which may then fail the same way; such a job already fails on the other
>   three hosts. The Docker slot uses its own store and no scratch.

>   bounds the slice. On the 31 GiB xev, nex and nux it is 45%, with a 50%
>   hard limit (about 14.0 and 15.6 GiB), since their cluster comes first:
>   about 15.6 GiB stays for the cluster services, which used 7 to 11G in
>   November 2026, and 8G of scratch leaves about 6 GiB under the throttle for
>   the job. On the 62.3 GiB xyz CI's limits are 64%, with a 69% hard limit
>   (39.9 and 43.0 GiB), and half the CPUs, split across the CI units since
>   the slice there is the shared budget below:
>   - The Podman API throttles at 59% (36.8 GiB), which holds the 24G scratch

>     the first slot only, takes 4.5 GiB, the 4.8 GB measured), with 0.8 GiB

>     hard limit is 61% (38.0 GiB), and it gets 40% of the CPUs.

>   The hard limits add up to 42.9 GiB, within the 69%, and the CPU shares to
>   the 50%. The throttles add up to slightly more than 64% with the filler's

>   shared budget: a 77% (48.0 GiB) hard limit, CPU and I/O weights 10, no
>   throttle and no CPU ceiling. The nix-daemon runs in its child slice

>   never anything outside. That leaves 14.3 GiB for the desktop (about
>   14 GiB in November 2026), the services and the ZFS ARC, which shrinks
>   under pressure to 2 GiB, so with both full and a busy desktop the rest of
>   the host has little margin left. The low weights make all building, deploy

>   adds or removes the mount never stops a running API and its job.
>   The tmpfs is not one of the runner hold's disk-floor paths

>   The volume directory's metadata went with the runroot too, so the same
>   `ExecStartPre` moves a non-empty volume directory aside under the reset's
>   trash name, and the reset deletes it at its lowest priority. Containers
>   that jobs leave behind while the API runs fill the
>   scratch; the store reset clears the scratch alone, keeping the images, at
>   any age once it reaches the host's `scratchTriggerPercent`: 70 percent by
>   default, 13 percent (3.1G) on xyz so a 12.8G large job and an 8G pool job
>   still fit its 24G. At 90 percent,
>   the recovery threshold, most new pool jobs fail, so the reset then pauses
>   the pool runners and waits for them to drain instead of waiting out their
>   quiet interval,

>   task container on either engine still holds the reset. Since the volumes
>   are on disk, a leftover adds little to the scratch while it can keep
>   running and holding memory in the CI slice: a cancelled job's EXIT trap
>   never runs, so the containers it started stay. On xev, before the volumes
>   moved, such leftovers held 33 to 51 percent of its 8G for hours in November
>   2026, below the trigger, and image builds that needed more failed with "No
>   space left on device". So any container that no running job owns (anything
>   but a running `FORGEJO-ACTIONS-TASK-*` container) also makes the same
>   reset of the scratch alone due, at the next check that finds the runners
>   quiet. Its age
>   and disk triggers clear the graphroot and the image store together. Either
>   way it frees the scratch before the API starts again
>   ([ADR-0105](../0105-offline-podman-store-reset.md)).

>   through the LAN cache. Turning scratch off uses the image store as the
>   graphroot again, with the volumes under it, which needs no migration; the
>   volume directory beside it stays until scratch is turned on again, when the
>   API's start moves it aside.
> - **Jobs larger than 8G of scratch** select `forgejo-podman-large`, which
>   only xyz's first pool slot serves, one at a time: the nix-packages Nix
>   update jobs (`update-t3code.yml` and `update-packages.yml`), one of which
>   kept 12.7G live. Such a job with its

> - **zram or a block device in RAM under the store**: compression would fit
>   more, but its memory is not charged to the CI slice, and a full device
>   fails writes with I/O errors that ext4 turns into a read-only filesystem
>   rather than "disk full".

> CI SSD writes are expected to fall, though by less than the 90 percent
> first estimated: what remains is image pulls, image imports, filesystem
> metadata and the volumes, which the trace of
> [#1027](https://git.alc.xyz/alcxyz/nix-config/issues/1027) did not measure
> apart from the container layers (job workspaces, nested containers' data
> volumes such as PostgreSQL's, and BuildKit's state, into which each build
> extracts its base images). Jobs spend less time waiting on the
> SATA disks. The hosts give the tmpfs size, at most, of RAM to CI on top of
> the jobs' own memory; the sizes and memory limits are per host in its
> configuration. A job that needs more scratch than its host offers fails

> additions wait longer. A reboot or an unmounted tmpfs loses

> runners are idle.

> a 256M scratch: image layers and volumes on disk and container data in RAM
> charged to the slice, an oversized write that fails with "No space left on device" while

> job's container, an API restart that empties the scratch and moves a leftover
> volume aside for the reset to delete, a fresh tmpfs that keeps the images,
> the API refusing to start without the tmpfs, the migration of an old store,
