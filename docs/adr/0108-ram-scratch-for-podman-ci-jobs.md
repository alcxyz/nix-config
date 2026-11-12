# ADR-0108: Keep Podman CI job scratch and volumes in RAM, images on disk

**Status:** Accepted
**Date:** 2026-11-08
**Amended:** 2026-11-10, a second pool slot on xyz sharing a 24G scratch ([#1027](https://git.alc.xyz/alcxyz/nix-config/issues/1027)); 2026-11-11, one memory budget for the nix-daemon and CI on xyz; 2026-11-12, volumes on disk beside the image store, since BuildKit builds that run dpkg failed with their state on tmpfs; 2026-11-12, any container that no running job owns resets the scratch at the next quiet check; 2026-11-12, volumes in an ext4 filesystem on zram, set aside from CI's memory, instead of on disk
**History:** [replaced text](archive/0108-ram-scratch-for-podman-ci-jobs-history.md)
**Applies to:** `modules/nixos/services/forgejo-actions-runner/podman-canary.nix`,
`podman-scratch-prepare.sh`, `podman-volumes-prepare.sh`, the runner module's `resourcePolicy`, the store reset of
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

BuildKit, which jobs start through the API with `docker buildx`'s
docker-container driver, keeps its snapshots in a volume. Its overlay
snapshotter, containerd's, mounts overlayfs with the `userxattr` option
inside a user namespace, except when its state directory is on tmpfs
(containerd `overlayutils.NeedsUserXAttr`, from containerd PR 7772 of 2022,
before tmpfs gained user xattrs in Linux 6.6). Without the option the
rootless overlay cannot store its xattrs, and renaming a new directory into a
directory from a lower layer fails with `EXDEV`, which dpkg does not work
around: from 2026-11-09, with volumes in the scratch, BuildKit builds that
installed Debian packages failed on all four hosts with "unable to
install new version of './etc/cron.hourly': Invalid cross-device link" or the
like, while Alpine `apk` builds passed. On kernel 7.3.3 and Podman 6.1.4 a
build of such a Dockerfile fails with BuildKit's state on tmpfs and passes
with it on disk, the graphroot still on tmpfs. The VM check, on the same
kernel, shows the same failure on tmpfs and a passing build with the state
on ext4 on a zram device.

With the volumes on the CI disks from 2026-11-12 to fix that, every job's
workspace volume wrote to the SSD again, while only image builds need a
filesystem other than tmpfs. For scale: the APIs created about 190 to 470
job workspace volumes per host from 9 to 12 November 2026 (from their
`volume create` journal entries), most of them while the volumes were
still in the tmpfs, against about 25 to 50 BuildKit state volumes.

## Decision

`services.forgejo-actions-runner.podmanCanary.scratch` puts the Podman API's
graphroot in a tmpfs at `/run/forgejo-podman-scratch` (`--root`), and keeps
the existing disk store at `/var/lib/forgejo-podman/storage` as its image
store (`--imagestore`). With `scratch.volumes`, on all four hosts, volumes
(job workspaces, service data, Buildx state) are in an ext4 filesystem on a
zram block device mounted at `/run/forgejo-podman-volumes`
(`--volumepath=/run/forgejo-podman-volumes/volumes`); without it they are in
`/var/lib/forgejo-podman/volumes` beside the image store. Container writable
layers, copy-ups and volumes are in RAM; image layers are on disk and
survive reboots.

- **Metadata outside the scratch.** The API runs a transient store
  (`--transient-store`): the libpod database and the container and volume
  metadata live in the runroot under `/run/forgejo-podman`, not in the
  size-limited tmpfs. A job that fills the scratch fails only its own data
  writes; the API still records, lists and removes containers. Without it,
  the VM check showed the database failing with "database or disk is full"
  for every job once one job had filled the scratch.

- **Volumes on ext4 in zram.** BuildKit's state is a volume, and on tmpfs
  its builds that run dpkg fail (see Context); on ext4 its snapshotter keeps
  `userxattr`. Podman places volumes by one path for all, and buildx creates
  the state volume itself, without options, so all volumes leave the tmpfs
  together. The API's root `ExecStartPre` makes the filesystem afresh at
  every API start: it unmounts the one an earlier start made, resets the
  zram device, which frees all its memory, sets its size, runs `mkfs.ext4`
  and mounts it with `discard,errors=remount-ro`, then creates the volume
  directory for the API's user. The device is the unit's own, added through
  `/sys/class/zram-control/hot_add` and recorded in
  `/run/forgejo-podman-volumes.device`, never `zram0`, which zram swap
  takes; none of the four hosts uses zram swap or `services.zram-generator`.
  The data is thrown away at the next start, so the filesystem has no
  journal, which would only add writes and an abort that turns it
  read-only, and no blocks reserved for root; it has 4 KiB blocks, so a
  discard frees whole zram pages, and an inode per block, four times
  ext4's default. Every non-empty file and directory takes at least a
  block, so the bytes run out before the inodes unless a job makes many
  empty files or short symbolic links. Trees of small files measured 7.9
  to 9.9 KiB per inode in November 2026 (a large npm package's
  `node_modules`, npm's own and a checkout of this repository), so with an
  inode per 8 KiB such a workspace would use up the inodes about when the
  bytes. The inode tables take 6.25 percent of the device's size, against
  3.1 with an inode per 8 KiB, which jobs cannot use, but zram stores their
  untouched zero pages without memory. The store reset counts the inodes
  as well as the bytes. Its compression is lz4, for speed. While
  anything still holds the last filesystem, the start fails closed with a
  message that names the holders: a process in any mount namespace with a
  file open or its working directory on it fails the unmount (the start
  names them with `fuser`), and another mount namespace that still mounts
  it, such as one a
  process made with `unshare` while the API ran, keeps the device open, so
  its reset fails with EBUSY. It never adds a second device, whose memory
  CI's limits would not account for. The API has `Restart=no` and nothing
  retries it, so once the holder is gone someone starts the API and the
  pool runners again with `systemctl start forgejo-runner-podman.service forgejo-podman-runner.service`, plus `forgejo-podman-runner-2.service` on xyz (`runners restart` skips failed and
  stopped units); until then CI on that host is down. Last, it writes the start's systemd invocation ID to
  `/run/forgejo-podman-volumes.started`, so the store reset can tell that
  the running API uses the filesystem.

- **One tmpfs and one volume filesystem per host.** Their sizes are per-host
  options, `scratch.size` and `scratch.volumes.size`, and every pool slot on
  a host shares them. A pool job had 8G of tmpfs for its container layers
  and volumes; that 8G is now split evenly, since how a job's data divides
  between the two was not measured apart, and either size can be moved
  later. xev, nex and nux run one pool slot
  ([ADR-0106](0106-runner-hold-for-games-and-low-disk.md)), so their 4G of
  tmpfs and 4G of volumes are that job's limits. xyz runs two, which share
  24G in all, as before, but no longer as one pool: 16G of tmpfs and 8G of
  volumes. Two pool jobs get the other hosts' 4G of each. A
  `forgejo-podman-large` job, which only the first slot takes, keeps its
  container in the tmpfs (the largest measured kept 12.7G live, nearly all
  of it its Nix store), which leaves 3.2G for the other slot's pool job's
  layers, and 2.4G with 0.8G of leftovers just below the trigger, less
  than the 4G it gets elsewhere, while that job's volumes share the 8G with
  the large job's workspace, which was not measured apart. Before, a pool
  job beside a large job had about 8G for its layers and volumes together,
  as one pool; the total is the same, but the layers now have a fixed
  share. A 17G and 7G split would give that pool job 4.2G of layers, but
  two pool jobs, the common case, only 3.5G of volumes each, so xyz keeps
  the even split. A job
  that writes past the free space fails with "No space left on device". The
  filesystems cannot give each job its own limit, since every job container
  writes as the same user, so a pool job that writes more than its share on
  xyz takes room from the other slot's job, which may then fail the same
  way; such a job already fails on the other three hosts. The Docker slot
  uses its own store and no scratch.
- **Memory.** tmpfs pages are charged to the cgroup that writes them, here
  the Podman API's unit `forgejo-runner-podman.service` in
  `forgejobuilds.slice`, which also holds the Docker slot's job. The tmpfs is
  mounted `noswap`, so scratch never reaches the swap disks: under memory
  pressure CI is throttled at memoryHigh or OOM-killed at memoryMax,
  inside its own budget. Each host's throttle holds its full scratch beside
  a memory budget for each pool job, so a full scratch fails a write before
  the slice is throttled while the jobs keep to those budgets. Nothing
  limits a single job's memory, so a job beyond its budget, or a Docker job
  beside full pool slots, can reach the throttle first; the hard limit still
  bounds the slice.
- **The volumes' memory is set aside.** zram's memory is charged to no
  cgroup, so CI's limits do not bound it. Each host sets it aside instead:
  the volume filesystem's size comes off the tmpfs and off CI's memory
  limits (on xyz also off the shared budget below), so CI's RAM, the
  limits and the zram together, is what it was before. The device's size
  is its reservation: zram stores a page it cannot compress well as the
  page itself, and no `mem_limit` is set that a write could reach. A full
  filesystem therefore returns "No space left on device" from ext4 and
  stays writable, and `discard` returns a deleted file's memory.
  Compression only lowers what the device uses. Two things can take it
  above its size: a table of about 0.4 percent of it, and zsmalloc's
  fragmentation, since a freed object's memory returns only once every
  object in its zspage is freed, so after many frees the device can hold
  more memory than the data it stores until it is compacted. The kernel
  compacts it under memory pressure (zsmalloc's shrinker), and the store
  reset compacts it at every check, every 15 minutes, while the running
  API uses it.
- **Write errors.** zram fails a write only when it cannot allocate memory
  for it, which with no `mem_limit` means the host itself has none left
  that it can reclaim without writing anything out. CI's limits and the
  device together fit what CI had before, so that takes a host-wide memory
  shortage from outside CI's budget, which is unlikely but not prevented.
  What ext4 then does depends on what the failed write held, as the VM
  check shows by causing such failures with zram's `mem_limit` on the
  hosts' kernel 7.3.3:
  - **File data:** ext4 logs a warning ("I/O error ... writing to inode")
    and records the error on that file, whose writer sees it only at
    `fsync` or `fdatasync` if it checks (ext4 reports nothing at `close`). The filesystem stays writable and its error
    count stays 0, so the store reset does not see it, and a job that does
    not check can go on with a file whose data is lost once its pages leave
    the page cache.
  - **ext4's metadata:** ext4 notices the failed write at its next
    metadata change ("Error while async write back metadata") and takes
    its error path, which under `errors=remount-ro` stops all writes and
    counts an error. Jobs then fail visibly rather than on a damaged
    filesystem, and the store reset makes it again. On 7.3.3 `mountinfo`
    still shows the mount and its superblock `rw`, the superblock with
    `emergency_ro`, so the reset reads ext4's error count, zero on the
    fresh filesystem. The VM check also causes an ext4 error directly
    (ext4's `trigger_fs_error`).

  The other error policies are worse: `errors=continue` would keep jobs
  writing to a damaged filesystem, and `errors=panic` would take the host
  down. The filesystem's page cache is charged to the API, as for any
  filesystem, and is reclaimable.
- **Per-host limits.** On the 31 GiB xev, nex and nux CI's throttle is 32%,
  with a 37% hard limit (about 10.0 and 11.5 GiB), and 4G of zram beside
  them, about 12.8% of the host, together the 45% and 50% (about 14.0 and
  15.6 GiB) they were before, since their cluster
  comes first: about 15.6 GiB stays for the cluster services, which used 7
  to 11G in November 2026, and 4G of scratch leaves about 6 GiB under the
  throttle for the job. On the 62.3 GiB xyz CI's limits are 51%, with a 56%
  hard limit (31.8 and 34.9 GiB), 8G of zram, 12.8% of the host, below the
  64% and 69% they were before, and half the CPUs,
  split across the CI units since the slice there is the shared budget
  below:
  - The Podman API throttles at 46% (28.7 GiB), which holds the 16G scratch
    and two pool jobs' 6 GiB each, as on the other hosts (a large job, in
    the first slot only, takes 4.5 GiB, the 4.8 GB measured), with 0.7 GiB
    for the engine, which idled at 0.1 to 0.2 GiB in November 2026. Its
    hard limit is 48% (29.9 GiB), and it gets 40% of the CPUs.
  - The Docker engine and its one job, which is light (Tofu plans, probes),
    throttle at 2% (1.2 GiB), with a 3% (1.9 GiB) hard limit and 7% of the
    CPUs. In one budget it took what the pool slots left; now it can no
    longer borrow their unused memory, and a heavier Docker job needs a
    larger share taken from the API's.
  - The shared Nix store's filler keeps its 3G cap, with 1G of staging
    ([ADR-0109](0109-shared-read-only-nix-store-for-podman-ci-jobs.md)), and
    gets 3% of the CPUs. It stages an input only when it finds no job
    running, so it meets full jobs only for one input.

  The hard limits add up to 34.8 GiB, within the 56%, and the CPU shares to
  the 50%. The throttles add up to slightly more than 51% with the filler's
  cap, and each holds its own unit. A game holds the runners and
  cancels their jobs after a two-minute grace
  ([ADR-0106](0106-runner-hold-for-games-and-low-disk.md)), so a game meets
  full CI for at most those minutes and the cleanup after.
- **One budget for the nix-daemon and CI on xyz.** The nix-daemon's builds
  (deploys, agents' local builds and remote build clients) have their own
  40G cap, and on their own the two caps added up to more than xyz's RAM.
  With `resourcePolicy.sharedBudget`, `forgejobuilds.slice` itself is the
  shared budget: a 64% (39.9 GiB) hard limit, the 77% (48.0 GiB) it had
  before less the 8G of zram beside it, CPU and I/O
  weights 10, no throttle and no CPU ceiling. The nix-daemon runs in its child slice
  `forgejobuilds-nixdaemon.slice`, with default weights inside it, no CPU
  ceiling, and its 40G cap, 2G of swap and `OOMPolicy=continue`. The CI
  units stay directly in `forgejobuilds.slice`, so their cgroup paths, which
  workflows in many repositories name as the BuildKit cgroup-parent, do not
  change. When both are busy they compete inside the budget, and at its
  limit the kernel kills the largest process in it, normally a build,
  never anything outside. With the zram, that leaves 14.4 GiB for the
  desktop (about 14 GiB in November 2026), the services and the ZFS ARC,
  which shrinks under pressure to 2 GiB, so with both full and a busy
  desktop the rest of the host has little margin left. The zram's 8G is
  set aside even while it holds little, so the nix-daemon's builds have
  8G less room than before when CI is idle. The low weights make all building, deploy
  builds included, yield to the desktop. CI's CPU shares are set at runtime
  from the processor count, by the resource policy unit and by the
  nix-daemon's start, which also clears a ceiling left on the slice. xev,
  nex and nux run no shared budget: CI's limits stay on their slice and
  their nix-daemon outside it.
- **Cgroup-parent for BuildKit.** A Podman pool job that starts BuildKit
  through the rootless API must give the API's delegated cgroup,
  `/forgejobuilds.slice/forgejo-runner-podman.service`, as its
  cgroup-parent. Each Podman runner start also passes the running API's
  `ControlGroup` to its jobs as `FORGEJO_PODMAN_CGROUP_PARENT`, so
  workflows can use it instead of naming the slice, with that path as the
  fallback.
- **Never on disk by accident.** The API starts after the tmpfs mount
  (`WantsMountsFor`), and its root `ExecStartPre` refuses to start unless a
  tmpfs is mounted there. The dependency is only a want, so a deploy that
  adds or removes the mount never stops a running API and its job. The
  volume filesystem's `ExecStartPre` likewise refuses the start unless the
  result is ext4 on the unit's own zram device, read-write with `discard`
  and of the configured size, and it refuses a mount point that is a
  symbolic link or holds any other mount, which it leaves alone. With the
  volumes in RAM no volume directory exists on disk, and the mount point's
  parent is root's, so the API cannot create volumes under it unmounted.
  Neither filesystem is one of the runner hold's disk-floor paths
  ([ADR-0106](0106-runner-hold-for-games-and-low-disk.md)).
- **Leftovers.** systemd removes the runroot whenever the API stops, so the
  tmpfs holds nothing an API start can still reference: the API's root
  `ExecStartPre` empties all of it, trash from an interrupted reset included.
  The volumes' metadata went with the runroot too, so the volume filesystem
  is made afresh, as above; with the volumes on disk, the `ExecStartPre`
  moves a non-empty volume directory aside under the reset's trash name, and
  the reset deletes it at its lowest priority. Containers and volumes that
  jobs leave behind while the API runs fill the scratch and the volume
  filesystem; the store reset clears the scratch alone, keeping the images,
  at any age once either reaches the host's `scratchTriggerPercent`, the
  volume filesystem in bytes or in inodes, whichever is fuller: 70
  percent by default, 25 percent on xev, nex and nux (1G of the tmpfs and
  about 0.9G of the volume filesystem, whose inode tables take 6.25 percent
  of the device), so a pool job still has 3G of tmpfs and about 2.8G of
  volumes, and 5 percent on xyz (0.8G of the tmpfs and about 0.4G of the
  volume filesystem, which leave a pool job beside a 12.8G large job 2.4G
  for its layers, and two pool jobs about 7.1G of the 8G device's volumes,
  3.5G each, after its 0.5G of inode tables). Restarting
  the API makes the volume filesystem afresh, and an unusable one (not
  mounted, another filesystem there, read-only, or with an ext4 error)
  makes the same reset due, but only while the running API uses it: the
  reset compares the started file with the API's invocation ID. With
  another filesystem mounted there, the API's start refuses, so that reset
  leaves CI on the host down until someone unmounts it and starts the API
  and the pool runners again. At 90 percent of
  either, the recovery threshold, or with an unusable volume filesystem,
  most new pool jobs fail, so the reset then pauses the pool runners and
  waits for them to drain instead of waiting out their quiet interval,
  whatever made it due; the Docker runner keeps the interval, and a running
  task container on either engine still holds the reset. A leftover
  container can add little to either while it keeps running and holding
  memory in the CI slice: a cancelled job's EXIT trap never runs, so the
  containers it started stay. On xev, while the volumes were in the tmpfs,
  such leftovers held 33 to 51 percent of its 8G for hours in November 2026,
  below the trigger, and image builds that needed more failed with "No space
  left on device". So any container that no running job owns (anything but
  a running `FORGEJO-ACTIONS-TASK-*` container) also makes the same reset of
  the scratch alone due, at the next check that finds the runners quiet. Its
  age and disk triggers clear the graphroot and the image store together.
  Either way it frees the scratch and the volumes before the API starts
  again ([ADR-0105](0105-offline-podman-store-reset.md)).
- **Switching.** The first start with scratch moves a disk store that still
  holds containers (a graphroot from before) aside under the reset's trash
  name; the reset's next check deletes it, and images are pulled again once
  through the LAN cache. The first start with the volumes in RAM likewise
  moves a non-empty volume directory on disk aside, and removes the empty
  one. Turning scratch off uses the image store as the graphroot again, with
  the volumes under it, which needs no migration; a volume directory beside
  it stays until scratch is turned on again, when the API's start moves it
  aside. Turning `scratch.volumes` off puts the volumes in that directory
  again.
- **Jobs larger than a pool job's share** select `forgejo-podman-large`,
  which only xyz's first pool slot serves, one at a time: the nix-packages
  Nix update jobs (`update-t3code.yml` and `update-packages.yml`), one of
  which kept 12.7G live. Such a job with its
  4.8G of memory would need about 20G of CI memory on a 31 GiB cluster node,
  more than its other services leave. These jobs wait while xyz is held for a
  game or off.

The Docker runner's store is unchanged: it serves the few jobs that still
select a Docker label.

## Alternatives Considered

- **Volumes in the scratch too**, as first decided: it kept their writes off
  the SSD as well, but BuildKit's builds that run dpkg fail there (see
  Context).
- **Volumes on disk beside the image store**, from 2026-11-12: BuildKit's
  builds work, but every job's workspace and service data writes to the SSD
  again.
- **systemd's zram-generator** (`services.zram-generator`, with `fs-type`
  and `mount-point`) for the device and its filesystem: no script, but it
  makes them once per boot, so an API start would have to empty the
  filesystem instead of making it afresh, a read-only one would need its
  setup unit restarted, and the API would depend on a unit that a deploy
  can restart under it.
- **BuildKit's native snapshotter**, set by each workflow
  (`--buildkitd-flags --oci-worker-snapshotter=native`): the state could stay
  in RAM, but it copies each layer whole. Building the GitOps Policy CI image
  took 1.0G of state with overlayfs and ran out of 6G of tmpfs at 5.3G with
  native, beyond a pool job's 8G with its container. The `fuse-overlayfs`
  snapshotter is not in the `buildx-stable-1` image.
- **Only BuildKit's state volume on disk**: Podman offers no per-volume
  default location, and buildx names a new volume for each builder and
  creates it without options; each workflow would have to create it first as
  a bind to a host directory.
- **A BuildKit whose containerd checks for user xattrs** instead of tmpfs, as
  a patched image or an upstream fix: it would let the volumes return to the
  scratch, but needs a maintained image or an upstream release first.
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
- **zram or a block device in RAM under the whole graphroot**, the
  container layers too: compression would fit more, but its memory is
  charged to no cgroup, so all of it would need a fixed reservation that
  CI's limits no longer bound, while tmpfs pages are charged to the API and
  return to the host when jobs end. For the volumes alone the reservation is
  smaller and buys working BuildKit builds. A device larger than its memory,
  bounded by zram's `mem_limit`, would fit more, but once that limit is
  reached writes fail with I/O errors rather than "No space left on
  device": failed file data is lost with only a warning, and failed
  metadata turns the filesystem read-only (see Write errors).
- **Writeback tuning or ext4 options**: longer dirty expiry or commit
  intervals would keep some short-lived files off the disk, but are global,
  risk data on other filesystems, and leave longer-lived job data on the SSD.
- **ZFS with compression and block cloning**: rejected by the owner; the
  runner hosts stay alike on ext4.
- **A new parent slice over the nix-daemon and a renamed CI slice** (for
  example `builds.slice` over `builds-forgejobuilds.slice`): it keeps CI's
  limits on one cgroup, but moves the engines' cgroups, which about 20
  repositories name as the BuildKit cgroup-parent, many of them building
  from `main`; rejected by the owner.
- **Lower separate caps for the daemon and CI**: each would leave the
  other's share unused when only one is busy; the owner chose one budget.

## Consequences

CI SSD writes are expected to fall by about 90 percent, as first estimated
with the volumes in the tmpfs, to image pulls, image imports and filesystem
metadata. Jobs spend less time waiting on the SATA disks. The hosts give the
tmpfs and volume sizes, at most, of RAM to CI on top of the jobs' own
memory, and the zram's share is set aside from CI's limits; the sizes and
memory limits are per host in its configuration. Whether the even split of
a pool job's 8G suits its jobs is open: `du` of the volume filesystem and
of the tmpfs at busy times, which needs root, would show it. A job that needs more scratch than its host offers fails
clearly instead of slowing the host. On xyz, with two slots, the store
reset and the shared Nix store's filler
([ADR-0109](0109-shared-read-only-nix-store-for-podman-ci-jobs.md)) find
fewer moments with no job running, so a due reset and the filler's
additions wait longer. A reboot, an unmounted tmpfs or an API restart loses
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
runners are idle. Enabling or resizing `scratch.volumes` likewise takes
effect at the next API restart, which makes the filesystem; the memory
limits the switch lowers apply at once, so switch while the runners are
idle. Until that restart the API keeps its volumes on disk, and the store
reset, whose started file names no running API, leaves the volume
filesystem alone (`volumes=not_in_use`): the deploy alone neither drains
the pool nor restarts the API. A reset that is due for another reason
restarts the API, and that start moves the volumes too. Turning it off leaves the last filesystem mounted, with what it held,
until the next reboot, or until an operator unmounts it and resets its
device (`/run/forgejo-podman-volumes.device` names it).

Turning the shared budget on takes effect at the switch, without a reboot.
systemd applies a changed unit's memory limits to its running cgroup when
the switch reloads it, so the slice's new limits and the engines' shares
apply at once, although the engines (`restartIfChanged = false`) keep
running. That includes the Docker engine's new 1.9 GiB hard limit, so a
Docker job running above it at the switch is OOM-killed; that is rare, as
the engine peaked at 92 MB after a boot in November 2026, but the switch
is best made while xyz's CI is idle. The switch restarts the nix-daemon in its child slice, and that
start moves CI's CPU ceiling from the slice onto the CI units, which takes
effect on running units too. The daemon's unit has `KillMode=process`: a
build that outlives the restart keeps the daemon's old cgroup in use, and
then the daemon is certain to run in the child slice only from its next
restart once that cgroup is empty, or from the next boot. `runners
restart`, while the runners are idle, restarts the units the switch left on
an older definition, the Podman runners among them, which then pass
`FORGEJO_PODMAN_CGROUP_PARENT`; until then their jobs use the fallback,
the same path. Turning the budget off again restores CI's limits on the
slice, and the resource policy, without the budget, clears the units' own
CPU shares when it runs (at `runners restart` or boot), since those
runtime values outlast the units' restarts.

The VM check `forgejo-podman-scratch-lifecycle` runs the production API on
the hosts' kernel (7.3.3 in November 2026) with a 256M scratch and 512M of
volumes: image layers on disk, container data in
RAM charged to the slice and volumes on a fresh ext4 on zram, an oversized
write that fails with "No space left on device" while
the slice reaches no memory.high event and the API keeps serving another
job's container, an API restart that empties the scratch, makes the volume
filesystem afresh and moves a volume directory left on disk aside for the
reset to delete, a fresh tmpfs that keeps the images, a BuildKit
docker-container build that installs a Debian package with dpkg, which fails
with EXDEV with its state on tmpfs and passes in the volume filesystem, a
volume filesystem filled to "No space left on device" that stays writable
and returns its memory once the volume is removed, a real ext4 error
(`trigger_fs_error`) that stops all writes while `mountinfo` still shows
`rw` and that the reset finds and repairs by making the filesystem again,
a leftover volume of empty files that uses up the inodes at 1 percent of
the bytes, so that new volumes fail with "No space left on device", which
the reset finds and repairs, writes that zram cannot store (through its
`mem_limit`), whose failed file data leaves the error count at 0 and whose
failed metadata ext4 counts as an error that the reset repairs, the API
refusing to start while a host process has its working directory in the
filesystem, naming it, or while another mount namespace holds the
filesystem, and starting once they are gone, the API refusing to start
without the tmpfs, or with another filesystem or a symbolic link where the
volumes go, the migration of an old store,
a reset by age that clears both parts, a scratch filled to the last byte that
resets alone and keeps the images, containers a finished job left behind that
reset the scratch alone at the next check, and deploys that turn scratch off and on
under a running API, after which the reset leaves an API that does not yet
use the volume filesystem alone.
