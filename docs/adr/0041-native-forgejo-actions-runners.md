# ADR-0041: Native Forgejo Actions runners

**Status:** Accepted
**Date:** 2026-05-07, updated 2026-11-05 (the runner restart pauses runners until their jobs finish, per nix-packages ADR-0017)
**Amended:** 2026-10-31, fewer slots on xyz and xev, and the runner hold of [ADR-0106](0106-runner-hold-for-games-and-low-disk.md) replaces the pressure guards; 2026-11-02, one `forgejo-docker` pool label and a 75% CPU ceiling on nux and nex; 2026-11-03, the Docker aliases and host-name labels retired; 2026-11-03, the dedicated `ci-fast` runners retired; 2026-11-03, runners named host-engine; 2026-11-05, a second pool slot on xyz as a trial ([#991](https://git.alc.xyz/alcxyz/nix-config/issues/991)); 2026-11-07, xyz keeps its second pool slot ([#991](https://git.alc.xyz/alcxyz/nix-config/issues/991)); 2026-11-08, one pool slot per host and higher memory limits for RAM job scratch ([#1027](https://git.alc.xyz/alcxyz/nix-config/issues/1027), [ADR-0108](0108-ram-scratch-for-podman-ci-jobs.md))
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
- exposes explicit pool and capability labels, never host names
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
which on `xyz` and `xev` also serves `ci-fast`
([ADR-0097](0097-ci-fast-runner-label.md)). Those ADRs govern the Podman runner
and `ci-fast`; this one governs the Docker runner and the shared runner
lifecycle and resource policy.

The Docker runners carry one label, `forgejo-docker`, on `xyz`, `xev`, `nux`
and `nex`, so Docker jobs can use every runner. There are no aliases and no
host-specific labels: a job that needs one host is an operator procedure that
adds a temporary label, not a standing label
([#957](https://git.alc.xyz/alcxyz/nix-config/issues/957)).

Runners are named host-engine: `<host>-docker` and `<host>-podman`, the
module defaults. A changed name registers the runner again at its next start,
and the operator deletes the old entry in Forgejo. The Docker runners stay
registered to the `alcxyz` user, not instance-wide like the Podman runners:
the runner injects deploy credentials into every Docker job, and a user
registration keeps those jobs to that user's repositories.

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
  Podman runner. Every Docker runner and every Podman pool runner admits one
  job, so each host's RAM job scratch is one job's limit
  ([ADR-0108](0108-ram-scratch-for-podman-ci-jobs.md)); the `xyz` and `xev`
  pool slots also serve `ci-fast`, and the `xyz` one `forgejo-podman-large` ([ADR-0097](0097-ci-fast-runner-label.md),
  [ADR-0106](0106-runner-hold-for-games-and-low-disk.md)).
- Runner shutdown stops polling before it waits up to `shutdownTimeoutSeconds`
  for admitted work to finish, then cancels it. That is the normal job timeout
  (3600 seconds) on `xev`, `nex` and `nux`, so routine host maintenance does
  not cancel in-progress CI work, and 120 seconds on `xyz`, so a game gets the
  disk back quickly. The systemd stop timeout adds 300 seconds for the
  cancellation and container cleanup.
- A switch restarts none of the runner units, the engine APIs or the
  resource policy (`restartIfChanged = false`), so a running job is never cut
  short by a deploy. Each of them records, when it starts, the resolved store
  paths of the unit file it started from, in a world-readable file under
  `/run/nixfleet-runners/started`. `nixfleet-runner-status` reports without
  root which of them runs an older definition than the deployed one, and why
  each stopped runner is down. `forgejo-runner-restart.service` restarts the
  flagged units once their running jobs finish. It waits for any Podman store
  reset or runner start or stop to end, then pauses the runners the restart
  touches: the flagged ones, or all of them when an API or the resource policy
  is flagged, since restarting those also restarts the runners that require
  them. A paused runner takes no new job, finishes its running ones, and reports
  `paused tasks=<running>` as its status text, through a patch in nix-packages'
  `forgejo-runner-cancellation` that every runner host uses. Once each reports
  no tasks it restarts the flagged units and ends the pauses, so a stop neither
  cancels a job nor leaves it to the shutdown timeout, on `xyz` as elsewhere.
  It waits up to the job timeout and 5 minutes
  (`restartWhenIdle.waitMinutes`), then gives up without restarting, so it never
  cancels a job on purpose. `nixfleet runners restart` starts it on each host
  (nix-packages ADR-0017); it changes nothing about the runner hold, whose stop
  of a paused runner is an ordinary stop.
- Forgejo runners pull work independently and provide no strict round-robin
  placement guarantee. Shared labels make all four hosts eligible, while the
  per-host caps prevent one server-worker from accepting a concurrent build
  burst.
- Each runner host enables the aggregate resource policy
  (`resourcePolicy.enable`) and places the containers its runners create in one
  top-level systemd slice, `forgejobuilds.slice`. The slice has an aggregate CPU
  ceiling equal to 50% of the host's online logical processors, a low CPU
  scheduling weight (10) under contention, a 40% memory throttling threshold,
  and a 50% hard memory limit. `xev`, `nex` and `nux` keep the 50% limit, since
  their cluster comes first, and throttle at 45% to hold their RAM job scratch
  (ADR-0108); `xyz`, with
  its slots beside the nix-daemon's 40G cap and the ZFS ARC, 40% and 45%. `nux` and `nex` raise the CPU
  ceiling to 75%, since k3s leaves them headroom; their storage latency
  decides whether they go further. Its I/O weight (10) is best
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
- Docker jobs can run on all four native runners through the shared
  `forgejo-docker` label. Excess work remains queued when their declared
  capacities are full. A job that asks for a retired label waits forever,
  since Forgejo has no label fallback.
- `nex` and `nux` contribute one slot per runner. This spreads eligible work
  without allowing concurrent runner jobs to amplify local resource contention
  on the smaller cluster members.
- `xyz` and `xev` each contribute two slots (one Docker, one pool), each
  within one aggregate
  resource budget. On `xyz`, builds can consume up to half the workstation's
  CPU and 45% of its memory, while memory reclaim and scheduling weights favor
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
