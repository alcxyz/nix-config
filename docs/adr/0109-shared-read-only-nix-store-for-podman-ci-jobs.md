# ADR-0109: Give Podman CI jobs a shared, read-only Nix store per host

**Status:** Accepted (trial on xyz)
**Date:** 2026-11-09, updated 2026-11-09 (which runs offer lists)
**History:** [replaced text](archive/0109-shared-read-only-nix-store-for-podman-ci-jobs-history.md)
**Applies to:** `modules/nixos/services/forgejo-actions-runner/nix-cache.nix`,
`nix-cache-{prepare,init,fill}.sh`, `podman-canary.nix` (`valid_volumes`),
the Podman runner pool, and the Nix workflows that opt in

## Context

Every Nix job in the Podman pool starts with an empty `/nix` in its
container, installs Nix with `cachix/install-nix-action`, and substitutes the
same closures from cache.nixos.org into it. Since
[ADR-0108](0108-ram-scratch-for-podman-ci-jobs.md) that store lands in the
host's RAM scratch instead of the CI SSD, but the trace for
[#1027](https://git.alc.xyz/alcxyz/nix-config/issues/1027) put Nix-installing
jobs at 40 to 50% of CI writes, and one job, the T3 nightly update check,
kept 12.7G live, which is why it needs xyz's `forgejo-podman-large` label.

The pull-through proxy of [ADR-0103](archive/0103-ci-nix-cache-proxy.md)
([#897](https://git.alc.xyz/alcxyz/nix-config/issues/897)) only replaced
internet downloads: each job still unpacked every path into its own store.
It was retired in [#953](https://git.alc.xyz/alcxyz/nix-config/issues/953) on
job time alone, without weighing SSD writes. Only a store the job uses
without copying avoids those writes.

VM spikes (#1038) ran the production rootless Podman API with RAM scratch:

- Binding a host store root's whole `nix` directory as `-v <root>/nix:/nix:O`
  fails while the lower files belong to a user outside the builder's user
  namespace: they appear as `nobody`, and single-user Nix as container root
  cannot open the lower database's lock file (`opening lock file
  "/nix/var/nix/db/big-lock": Permission denied`).
- Binding only the store directory, `-v <root>/nix/store:/nix/store:O`, works
  for paths the job's database lists: the overlay root is the container's own
  upper directory, so Nix creates new paths there, in the graphroot on the
  RAM scratch, and with a copy of the lower database in the container's own
  `/nix/var/nix/db` it sees every lower path as valid.
- A lower path the job's database does not list (a snapshot older than the
  store, or no snapshot, as after installing Nix on top) breaks the job while
  the lower files appear as `nobody`: Nix deletes an invalid path before
  substituting it, starting with a `chmod`, which the overlay refuses. Shown
  through an ID-mapped bind that presents the filler's files as the API
  user's (root in the job's user namespace), the same job copies up and
  whites out the path in its upper, substitutes it again, and leaves the
  lower directory byte-for-byte unchanged, for directory paths too.
- The Docker-compatible API passes `:O` through act's `Binds` unchanged, and a
  bind mount made on the host after the API started is visible to new
  containers.

## Decision

`services.forgejo-actions-runner.podmanCanary.nixCache` keeps a persistent
Nix store per host as a chroot store at `dataPath`, owned by a dedicated
filler user, preferably on the CI disk: `/ext4/ci/forgejo-nix-cache` on xyz.
The Podman store reset ([ADR-0105](0105-offline-podman-store-reset.md))
renames only `/var/lib/forgejo-podman/storage` and leaves it alone.

- **Location.** Every ancestor of `dataPath` must be a directory only root
  can change; the preparation refuses the store otherwise, and a module
  assertion keeps it out of `/var/lib/forgejo-podman`, which the API's user
  owns and could plant links or swap directories in. Hosts whose only CI-disk
  directory is builder-owned need a root-owned parent: nex and nux can use
  `/var/lib`, which is on their CI disk; xev is not covered yet. The default,
  `/var/lib/forgejo-ci-nix-cache`, avoids `/var/lib/forgejo-nix-cache`, which
  ADR-0103's proxy may have left behind.
- **Exposed read-only and ID-mapped.** A root unit (`forgejo-nix-cache-prepare`)
  creates the store root with `mkdir` under its root-owned parent if missing,
  opens it once, checks through that descriptor that it is a directory, not a
  link, owned by the filler with mode 0755, and binds exactly that inode
  (`/proc/self/fd/N`) at `/run/forgejo-nix-cache` before the Podman API
  starts. The bind is ID-mapped (`X-mount.idmap`): the filler's user and group
  appear as the API user's (`forgejo-podman-builder:forgejo-podman`), which
  is root in the job's user namespace, so a job can replace a lower path its
  database does not list in its own upper. The bind is assembled in
  `/run/forgejo-nix-cache-stage`, a private, root-only tmpfs whose mounts
  neither propagate nor can be reached, made read-only there, checked for
  device, inode, mapped owner and the read-only flag, and only then moved
  into place, so the published path is never writable, not even briefly. A
  container that binds it again gets a locked read-only mount, and the
  builder cannot rename or replace a mount under root-owned `/run`.
- **Bind sources always exist.** The filler itself, started unprivileged
  through `setpriv` with no capabilities, gives a fresh store an empty
  `nix/store` and `job/` with an empty, valid database snapshot, but no `nix`
  until the first fill; root writes nothing inside the filler's tree. A
  refused or stopped store gets an empty read-only tmpfs placeholder with the
  same paths, assembled the same way, and the drop directory is mounted and
  set to mode 1733 on every run, so container creation never fails on a
  missing bind source and the workflow falls back to `install-nix-action`. A
  refused start fails the unit, which keeps the filler from running; its
  next start replaces the placeholder.
- **Jobs read, never write.** A workflow opts in by mounting
  `/run/forgejo-nix-cache/nix/store:/nix/store:O` (an overlay: the store as
  lower layer, a throwaway upper in the graphroot, which is RAM scratch) and
  `/run/forgejo-nix-cache/job:/nix-cache:ro`, copying
  `/nix-cache/db/{db.sqlite,schema}` into `/nix/var/nix/db`, and running
  Nix from `/nix-cache/nix/bin`. The lower database is never opened by a job.
  The pool runner's `valid_volumes` allows these paths and the drop directory
  only on hosts with the cache; elsewhere the runner drops the binds and the
  workflow falls back to `install-nix-action`, which also works on top of a
  populated lower store. Fork pull requests and workflows that do not opt in
  keep `install-nix-action`.
- **Only the filler writes, and only trusted content.**
  `forgejo-nix-cache-fill` runs on a timer (`interval`, 15 minutes) as its own
  system user with no credentials: its own `nix.conf` (no host
  configuration, `netrc-file = /dev/null`, no access tokens, registries or
  builders), `/etc/nix`, `/etc/gitconfig`, `/root`, `/run/secrets`, SSH keys
  and the runner state inaccessible, no capabilities, and Git without
  prompts, askpass or SSH. It adds only:
  1. store paths whose narinfo is signed by a key in `trustedPublicKeys`
     (`cache.nixos.org-1`), substituted from `substituters`
     (`https://cache.nixos.org`) with `require-sigs = true`; and
  2. `github`, `gitlab` and `sourcehut` flake inputs on their canonical
     public hosts (a SourceHut owner may start with `~`), pinned to a commit
     and a `narHash`, fetched without credentials. Every other input is refused before any request: a `host`
     override, a URL, `submodules`, a branch instead of a commit, and the
     `tarball`, `git`, `file`, `path`, ssh and indirect types, since a URL, a
     redirect or a submodule could reach other hosts, private ones included.
     An input whose store path, which follows from its `narHash`, is already
     valid is rooted again without fetching. A missing one is fetched into its
     own throwaway store on the unit's private `/var/tmp`, a tmpfs of
     `stageSize` (4G) that also holds Nix's download caches, its NAR hash is
     compared with the pin there, and only then is it copied into the cache,
     so a mismatch never reaches it. The staging store and the caches are
     deleted after every input, so a rejected input leaves no bytes behind;
     the tmpfs is charged to the filler, whose memory limit is `stageSize`
     plus 2G. A private input such as nix-secrets or
     pandora fails to fetch and is skipped, and jobs fetch it into their
     scratch as now.

  It never builds: `.drv` entries are dropped, `max-jobs = 0`, and a path is
  only realised by substitution, so locally built paths never enter. The
  guarantee is content-based, not source-based.
- **Lists are advisory.** Jobs leave path lists (`*.paths`) and flake locks
  (`*.lock`) in `/run/forgejo-nix-cache-drop`, a 64M tmpfs that is sticky and
  writable by all but listable only by the filler. Lists are not private
  between jobs: every job runs as the same host user, which can open,
  replace or delete another job's list by name, so they carry only public
  store paths and lock files. The filler moves what it reads into a queue in
  its private state directory (`/var/lib/forgejo-nix-cache-fill`, mode 0700),
  bounded to 200000 paths and 500 inputs with the oldest dropped first, and
  works from that queue on every fill. An entry leaves it once it is added,
  found present, or tried and refused (a refused input type, a failed fetch
  or pin check, a path no trusted cache serves); entries held back by a
  running job or the budget wait for a later fill. After each fill, root
  deletes every entry in the drop directory that has lain there since before
  the previous fill started (by change time, never following links), so
  dotfiles and directories, which the filler cannot remove, do not pile up,
  while an offer a job is still writing, which is newer, survives. A list names the paths a run
  added and everything they reference, including outputs already in the
  store; the filler roots the listed paths it already has again, which
  renews them without fetching, and substitutes the missing ones. A job's
  whole `nix path-info --all` would name the entire lower store and keep
  every path alive forever.

  The workflows offer lists from pushes to the repository's default branch
  (`forgejo.ref` equal to it) and from pull requests whose head branch is in
  the same repository; fork pull requests neither use the store nor offer
  lists. A list is only a hint: what enters is decided by the content rules
  above, never by who offered it, and a pull request's code could write the
  drop directory anyway, without the workflow's offer step. Offering from
  default-branch pushes alone would leave the store nearly empty for
  nix-packages, whose validation runs on pull requests and on pushes to
  `main`, while its default branch is `dev`. Any job could write there: a
  hostile list can only make the filler fetch public signed paths or pinned
  public sources, and keep paths alive, within the ingestion budget. The
  worst it can do is take the cache's use away, never its integrity: each
  fill adds about `runLimit`, and collection then evicts the oldest root
  directories whole, however much they hold, to get under `sizeCap`. A job
  that keeps offering the same large list renews its paths on every fill, so
  they stay recent: the store can sit at the cap holding only them, with
  every other root evicted and ingestion stopped, until those offers stop
  and the paths age out. Jobs then substitute what they miss into their
  scratch, as without the store. The filler reads only
  regular files with plain names, never follows links, caps each file at
  16 MiB, and keeps only paths that follow Nix's rules (a 32-character
  base-32 hash, a name of at most 211 allowed characters not starting with a
  dot). A validity check that fails for a batch is repeated path by path, and
  a path whose state stays unknown is skipped, never taken as present.
- **Ingestion budget.** Before each missing closure and each input, the
  filler checks the store's size (the sum of its NAR sizes) against
  `sizeCap` (30G), what this run has added so far against `runLimit` (5G),
  and the CI filesystem's free space against `minFreePercent` (20); past any
  of them it stops adding for that run, whether or not collection can run. A
  run overshoots the cap and its limit by at most the one closure it last
  admitted, so one list can make a fill write at most about `runLimit`.
  Lists are written under a dot name and renamed to `*.paths` or `*.lock`
  once complete; the filler reads and removes only those two kinds.
- **No changes under running jobs.** Changing an overlay's lower directory
  while it is mounted is undefined in overlayfs. Before each addition (a
  substitution, an input copy, the jobs' Nix) and each collection step, the
  filler looks for a running `FORGEJO-ACTIONS-TASK-*` container (its conmon's
  command line, readable without the Podman socket); while one runs, it only
  roots again what is already there and defers adding and collecting to a
  later run. A busy host therefore fills only between jobs.
- **Collection.** Each run that adds or renews paths makes one GC root
  directory named by its time. Roots older than `maxAgeDays` (14) are
  dropped, then the oldest roots until the store is under `sizeCap`, each
  followed by `nix-store --gc`; the jobs' Nix stays rooted. Roots renewed
  within the last day are never evicted for the cap: if only those remain,
  the store stays over the cap and ingestion stays stopped, so a hostile
  list cannot evict what jobs use now. Right before each
  `nix-store --gc` and each eviction, the filler checks for a running job as
  above and skips the rest of the collection if there is one, since that
  job's database copy may name paths a collection would delete.
- **Snapshot.** When the set of valid paths changed and every valid path is
  rooted, the filler publishes a database snapshot (`VACUUM INTO`) under
  `job/db`, keeping the previous one for jobs still copying it. If the check
  for unrooted paths itself fails, it also keeps the old snapshot. While
  unrooted paths exist (part of a failed substitution, or roots that expired
  while collection waited), it keeps the old snapshot, so jobs never see a
  path that is not kept. Paths the store holds but a job's snapshot does not
  list are harmless: the job substitutes them again into its upper.
- **Trial on xyz.** Only xyz enables it until the nix-packages validation is
  measured; then the other pool hosts and the other Nix workflows (pandora,
  nix-config, teams-chat, vidown).

Success is measured against the #1027 baseline on two criteria, not one: CI
disk writes per day and per Nix job, and job time. Writes are an explicit
criterion because ADR-0103's proxy was retired on job time alone. The heavy
Nix jobs move back from `forgejo-podman-large` to the shared pool if their
scratch then fits every host, or the reason they cannot is recorded here.

## Alternatives Considered

- **A shared nix-daemon per host with its socket in job containers**: jobs
  would use the store without copying, but as daemon clients that can build
  and substitute into the shared store, so a pull request's build would
  enter what other jobs trust unless every job were an untrusted user with a
  restricted daemon; a daemon is also one more long-running service per
  host. The overlay keeps the boundary by construction: jobs cannot write
  the lower store at all.
- **The store owned by the filler and shown as `nobody`** (a plain bind): a
  job fails on any lower path its database does not list, as the spike
  showed, which happens during a fill, while publishing waits, and for every
  job that falls back to installing Nix.
- **Nix's `local-overlay://` store** inside the job: it would read the lower
  database read-only instead of copying it, but is experimental, checks the
  overlay mount it cannot see from inside the container, and needs Nix's
  view of the upper layer.
- **The read-only store as a substituter** (`local?root=...`): copies every
  path into the job's store, so the writes and the scratch stay.
- **The pull-through proxy of ADR-0103**: retired; it saved neither writes
  nor measurable time.
- **Filling from jobs' own stores**: would let a job place locally built
  paths into what others trust.
- **Tarball and git inputs from public hosts**, with an address check: a
  redirect or a submodule reaches hosts the check never saw.

## Consequences

Opted-in jobs on xyz skip installing Nix and do not download or unpack paths
the store already holds; their scratch holds only new paths, paths their
snapshot does not list, and a copy of the database, about 1.2 KiB per valid
path in the VM. The store's growth writes to the CI disk once per new path
instead of once per job. The store and its database are readable by every
pool job on the host, which is acceptable only because they hold public,
signed or hash-pinned content. ID-mapped binds need a filesystem that
supports them; ext4 does.

The store counts toward the CI disk's use for the store reset's trigger and
the runner hold's disk floor; `sizeCap` and `minFreePercent` must leave both
their margins. Busy hosts may defer adding, collection, and with it new
snapshots after an expiry, for as long as jobs keep running.

Known limits: the running-job check narrows the races but does not close
them. A job that starts right after a check sees its lower store change
under it while a substitution, an input copy or a collection completes; it
may miss a path its snapshot names and fail, and then reruns. Revision-pinned GitHub inputs are downloaded from
`https://github.com/<owner>/<repo>/archive/<rev>.tar.gz`, not through the
API, so the API's rate limit for anonymous requests does not apply, and an
input already in the store is not downloaded again. Flake inputs of other
types, such as Forgejo-hosted tarballs, are not cached. The prepare unit has
`restartIfChanged = false`, so a deploy that changes it takes effect at its
next restart or a reboot. When prepare publishes a new mount, which happens
only at such a restart or a boot, it unmounts the old one before moving the
new one in, so `/run/forgejo-nix-cache` is briefly an empty root-owned
directory: never writable, but a job created in that instant fails to start.
Disabling the cache stops it, which leaves the
empty read-only placeholder at the same paths: jobs that still bind them
start and fall back to `install-nix-action` until `runners restart` gives
the runner its configuration without the binds. The placeholder and the
drop directory stay mounted until the next reboot, and the store stays on
disk to delete by hand.

The VM check `forgejo-podman-nix-cache-lifecycle` covers a fresh store
exposed read-only and ID-mapped, exactly the validated inode, assembled in a
private root-only staging directory, with its bind sources before the first
fill and a job falling back there; the filler
adding signed file and directory paths with their closure and a pinned
GitHub input while refusing unsigned, other-key and local paths, `.drv`
entries, a malformed name and a symlinked list; a GitHub archive served with
200 OK but not matching its pin neither stored nor published; a private
repository failing, and other types, a host override, submodules and a
branch refused without any request, a SourceHut owner with a tilde
accepted and a GitHub one refused, and the staging tmpfs empty after the
inputs; dotfiles and directories in the drop directory removed after the
fill; that the fixture server never sees
credentials although the host's netrc, root's netrc and a Git credential
store hold some; an input already present rooted again without a request;
jobs whose database does not list a lower directory path, from an older
snapshot or none at all, replacing it in their upper while the lower store
stays unchanged; a job that reads the lower store, substitutes and adds paths
into its RAM scratch and leaves the lower store unchanged; that no bind of
the store is writable from a container; a job's list renewing the lower path
it used and adding its signed path but not its local one; a fill with a job
running that only renews and neither adds nor collects; ingestion stopping
at the cap; expiry by age keeping
renewed paths; eviction by the cap; a store reset that leaves the store and
its mount alone; a stopped unit leaving a placeholder that jobs still start
on; and a store someone else owns refused with a placeholder, replaced on
the next start with the drop directory's mode intact.
