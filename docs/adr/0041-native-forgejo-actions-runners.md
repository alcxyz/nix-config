# ADR-0041: Native Forgejo Actions runners

**Status:** Accepted
**Date:** 2026-05-07
**Amended:** 2026-10-31, fewer slots on xyz and xev, and the runner hold of [ADR-0106](0106-runner-hold-for-games-and-low-disk.md) replaces the pressure guards
**History:** [replaced text](archive/0041-native-forgejo-actions-runners-history.md)
**Applies to:** Forgejo Actions runner services, `hosts/xyz`, `hosts/xev`, `hosts/nux`, `hosts/nex`

## Context

Forgejo Actions runners once ran from GitOps-managed Kubernetes Deployments.
Those pods installed Docker CLI and other tools at runtime, mounted the host
Docker socket, and then registered runner labels with Forgejo.

This proved brittle. During a DNS outage, the `nux` and `nex` runner pods
started but failed to install Docker CLI. They still registered Docker-capable
labels, which caused jobs to be scheduled onto runners that could not execute
Docker-backed tasks.

The runner is not a normal application workload. It is host infrastructure that
depends on host container runtime capabilities and has host-level power when it
uses Docker.

## Decision

Manage Forgejo Actions runners as native NixOS/systemd services, through
`modules/nixos/services/forgejo-actions-runner/`.

The NixOS module:

- installs `forgejo-runner`, Docker/Podman client tooling, Git, curl, and other
  required tools declaratively
- generates runner configuration from Nix options
- reads registration and workflow secrets from SOPS-managed files
- verifies required runtime capabilities before registering or polling for jobs
- exposes explicit host and capability labels
- supports Docker-backed job labels for clean per-job containers
- fails the systemd unit if required tools, sockets, or secrets are unavailable
- bounds unused Docker build cache according to both filesystem pressure and
  cache recency

Native Docker-capable runners run on `xyz`, `xev`, `nux`, and `nex`. Normal
jobs use Docker-backed labels. No host-backed labels are exposed unless a
current trusted infrastructure workflow needs one. Each of the four hosts runs
its Docker runner against the dedicated rootless CI daemon of
[ADR-0072](0072-isolated-runner-docker.md) (`isolatedDocker.enable`), and also
runs a Podman pool runner ([ADR-0074](0074-phased-podman-coexistence.md)),
registered instance-wide ([ADR-0100](0100-instance-wide-podman-runners.md)),
with the `ci-fast` runners of [ADR-0097](0097-ci-fast-runner-label.md). Those
ADRs govern the Podman and `ci-fast` runners; this one governs the Docker
runner and the shared runner lifecycle and resource policy.

The default runner pool is represented with labels:

- `forgejo-docker-primary`, `ubuntu-latest`, and `docker` are exposed by `xyz`,
  `xev`, `nux`, and `nex`, allowing routine jobs to use every runner.
- `forgejo-docker-secondary` remains on `nux` and `nex` as a compatibility
  label for workflows that explicitly request it.
- host-specific Docker labels (`xyz`, `xev`, `nux`, `nex`) remain available for
  workflows that intentionally need one host.

## Required Properties

- No package installation during service startup.
- No runner registration if required checks fail.
- Docker-capable labels only on hosts intentionally allowed to expose the Docker
  socket to CI jobs.
- Normal CI jobs use container-backed Forgejo labels, preserving clean job
  environments.
- Nix builds inside unprivileged Docker jobs must not assume that Nix can create
  a second sandbox. Workflows that build multi-package closures must stage
  dependency builds and keep Nix's deliberately nonexistent build home absent
  between invocations.
- Do not solve missing inner Nix sandboxing by granting normal job containers
  privileged mode or by moving routine jobs onto a host execution label.
- Host-level labels are explicit and used only for trusted infrastructure
  workflows.
- Runner admission is explicit in per-host capacity, set for the Docker and the
  Podman runner. Every Docker runner admits one job. The Podman pool admits
  one job on `xyz`, which also runs games and media services, two on `xev`,
  and one on `nex` and `nux`; the `ci-fast` runners on `xyz` and `xev` add one
  slot each ([ADR-0097](0097-ci-fast-runner-label.md),
  [ADR-0106](0106-runner-hold-for-games-and-low-disk.md)).
- Runner shutdown stops polling before it waits up to `shutdownTimeoutSeconds`
  for admitted work to finish, then cancels it. That is the normal job timeout
  (3600 seconds) on `xev`, `nex` and `nux`, so routine host maintenance does
  not cancel in-progress CI work, and 120 seconds on `xyz`, so a game gets the
  disk back quickly. The systemd stop timeout adds 300 seconds for the
  cancellation and container cleanup.
- Forgejo runners pull work independently and provide no strict round-robin
  placement guarantee. Shared labels make all four hosts eligible, while the
  per-host caps prevent one server-worker from accepting a concurrent build
  burst.
- Each runner host enables the aggregate resource policy
  (`resourcePolicy.enable`) and places the containers its runners create in one
  top-level systemd slice, `forgejobuilds.slice`. The slice has an aggregate CPU
  ceiling equal to 50% of the host's online logical processors, a low CPU
  scheduling weight (10) under contention, a 40% memory throttling threshold,
  and a 50% hard memory limit; `xyz`, with three slots beside the nix-daemon's
  40G cap and the ZFS ARC, uses 25% and 35%. Its I/O weight (10) is best
  effort. With the
  dedicated CI daemon of ADR-0072, the daemon and its workers run below that
  slice; a runner that uses the shared host daemon instead passes the slice as
  the cgroup parent, and Docker uses the systemd cgroup driver so the parent
  name resolves to that slice.
- Calculate the CPU quota from the online processor count when the service
  starts. A systemd quota of `50%` means half of one processor, rather than half
  of the machine, so a fixed literal would implement the wrong limit.
- Keep workstation protection contention-aware. The build slice may use its
  bounded CPU budget while the machine is idle, and its low CPU and I/O weights
  make it yield when interactive work competes. The resource policy itself
  watches no game process; the runner hold of
  [ADR-0106](0106-runner-hold-for-games-and-low-disk.md) stops `xyz`'s
  runners while a game runs.
- Resource controls on Forgejo-created containers do not cover containers or
  BuildKit workers started through a mounted shared host Docker socket. Such
  workflows need the isolated CI Docker daemon of ADR-0072, or equivalent
  daemon-side enforcement, before they can rely on the aggregate policy.
- Linux cgroup writeback does not support buffered ZFS writeback. The I/O weight
  therefore cannot guarantee protection from ZFS-backed write saturation; the
  slot counts are the lever that works.
- Build cache is preserved while the host filesystem is healthy. Under moderate
  pressure, only cache unused for the configured grace period is eligible for
  removal; under critical pressure, all unused cache may be reclaimed. Running
  containers, images needed by containers, and volumes are outside this policy.
- No guard pauses or freezes runner containers under I/O pressure. On the
  isolated hosts the runner hold holds admission for a game or a low disk; a
  runner on the shared host daemon has no hold.

## Alternatives Considered

**Keep Kubernetes runners and fix startup scripts** - improves symptoms but keeps
the wrong ownership model. The runner remains a pod that depends on host Docker
and runtime package installation.

**Use a custom runner container image** - acceptable as a temporary mitigation,
but still requires Docker socket mounts and Kubernetes runner lifecycle.

**Run all jobs directly on the host** - rejected for normal CI because it removes
clean per-job environments. Host-level jobs should be explicit exceptions.

**Detect individual games and pause the runner** - rejected for the workstation
resource policy. It couples build admission to compositor- and game-specific
state, while aggregate CPU and memory limits plus low contention weights protect
interactive work regardless of which foreground application creates pressure.
ADR-0106 later stops `xyz`'s runners while a game runs, rather than pausing
work.

**Set CPU and memory limits on each container independently** - rejected because
two admitted jobs, their service containers, and their step containers could
multiply the intended host budget. A shared parent slice enforces one aggregate
limit across the containers Forgejo Runner creates.

## Consequences

- Runner implementation lives in `nix-config`. GitOps no longer runs
  Kubernetes runner Deployments or their PVCs.
- CI trust improves because host capabilities are declared and checked by NixOS
  instead of discovered after pod startup.
- Docker-capable runners remain trusted infrastructure and must not be exposed to
  untrusted workloads.
- Routine workflows can run on all four native runners through the shared
  `forgejo-docker-primary`, `ubuntu-latest`, and `docker` labels. Excess work
  remains queued when their declared capacities are full.
- `nex` and `nux` contribute one slot per runner. This spreads eligible work
  without allowing concurrent runner jobs to amplify local resource contention
  on the smaller cluster members.
- `xyz` contributes three slots (one Docker, one pool, one `ci-fast`) and
  `xev` four (one Docker, two pool, one `ci-fast`), each within one aggregate
  resource budget. On `xyz`, builds can consume up to half the workstation's
  CPU and 35% of its memory, while memory reclaim and scheduling weights favor
  interactive workloads under contention.
- The policy does not provide a hard ZFS I/O guarantee. Nested Docker work is
  contained only through the dedicated CI daemon of ADR-0072, not by limits on
  the runner service process.
- Nix-heavy workflows remain Docker-backed. Their verification scripts isolate
  build stages and may clean Nix's fake build home only after positively
  identifying an explicitly opted-in ephemeral job container.
- Runner hosts check filesystem pressure frequently (every 15 minutes) instead
  of relying only on a fixed cleanup schedule. The default policy starts
  age-filtered build-cache pruning at 70% used, permits all unused cache to be
  pruned at 80% used, aims for 40% free, and retains at least 10 GB of BuildKit
  cache; the grace period is 48 hours. Weekly cleanup on a shared host daemon
  that runners use removes only build cache unused for 7 days and retains the
  same cache floor; application and rollback images remain owned by their
  consumers. Where runners use the dedicated CI daemon, the host daemon's
  weekly cleanup removes build cache unused for 7 days and dangling images,
  leaving tagged images, containers and volumes to host workloads. The
  dedicated daemon may also remove old unused images because its entire image
  store is disposable runner state (ADR-0072 retention).
- Rebuild QA guardrails for runner hosts remain open in
  [#53](https://git.alc.xyz/alcxyz/nix-config/issues/53): post-rebuild
  registration and heartbeat checks, and capability probes covering every
  advertised label.
