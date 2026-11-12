**History of** [ADR-0108](../0108-ram-scratch-for-podman-ci-jobs.md): text replaced on 2026-11-10, 2026-11-11 and 2026-11-12.

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
