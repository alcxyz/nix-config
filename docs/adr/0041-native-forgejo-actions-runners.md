# ADR-0041: Native Forgejo Actions runners

**Status:** Implemented (amended 2026-09-10: shared routine runner pool and workstation resource policy)
**Date:** 2026-05-07
**Applies to:** Forgejo Actions runner services, `hosts/xyz`, `hosts/xev`, `hosts/nux`, `hosts/nex`

## Context

Forgejo Actions runners previously ran from GitOps-managed Kubernetes
Deployments. Those pods installed Docker CLI and other tools at runtime, mounted
the host Docker socket, and then registered runner labels with Forgejo.

This has proven brittle. During a DNS outage, the `nux` and `nex` runner pods
started but failed to install Docker CLI. They still registered Docker-capable
labels, which caused jobs to be scheduled onto runners that could not execute
Docker-backed tasks.

The runner is not a normal application workload. It is host infrastructure that
depends on host container runtime capabilities and has host-level power when it
uses Docker.

## Decision

Manage Forgejo Actions runners as native NixOS/systemd services.

The NixOS module should:

- install `forgejo-runner`, Docker/Podman client tooling, Git, curl, and other
  required tools declaratively
- generate runner configuration from Nix options
- read registration and workflow secrets from SOPS-managed files
- verify required runtime capabilities before registering or polling for jobs
- expose explicit host and capability labels
- support Docker-backed job labels for clean per-job containers
- fail the systemd unit if required tools, sockets, or secrets are unavailable
- bound unused Docker build cache according to both filesystem pressure and
  cache recency

Run native Docker-capable runners on `xyz`, `xev`, `nux`, and `nex`. Normal
jobs use Docker-backed labels. No host-backed labels are exposed unless a
current trusted infrastructure workflow needs one.

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
- Runner admission is explicit in per-host capacity. The three Kubernetes
  server-workers each admit one job at a time; `xyz` admits two and retains a
  lower CPU scheduling weight for interactive use.
- Forgejo runners pull work independently and provide no strict round-robin
  placement guarantee. Shared labels make all four hosts eligible, while the
  per-host caps prevent one server-worker from accepting a concurrent build
  burst.
- `xyz` places every job, step, and service container created by Forgejo Runner
  in one top-level systemd slice. The slice has an aggregate CPU ceiling equal
  to 50% of the host's online logical processors, a lower CPU scheduling weight
  under contention, a 40% memory throttling threshold, and a 50% hard memory
  limit. Its I/O weight is best effort. Docker uses the systemd cgroup driver so
  the configured parent name resolves to that slice.
- Calculate the CPU quota from the online processor count when the service
  starts. A systemd quota of `50%` means half of one processor, rather than half
  of the machine, so a fixed literal would implement the wrong limit.
- Keep workstation protection contention-aware without a game-process watcher.
  The build slice may use its bounded CPU budget while the machine is idle and
  its low CPU and I/O weights make it yield when interactive work competes.
- Resource controls on Forgejo-created containers do not cover containers or
  BuildKit workers started through the mounted Docker socket. Workflows that do
  this need an isolated CI Docker daemon or equivalent daemon-side enforcement
  before they can rely on the aggregate policy.
- Linux cgroup writeback does not support buffered ZFS writeback. The I/O weight
  therefore cannot guarantee protection from ZFS-backed write saturation; keep
  this limitation visible and qualify a stronger pressure or storage boundary
  separately.
- Build cache is preserved while the host filesystem is healthy. Under moderate
  pressure, only cache unused for the configured grace period is eligible for
  removal; under critical pressure, all unused cache may be reclaimed. Running
  containers, images needed by containers, and volumes are outside this policy.
- Runner hosts enable a system I/O pressure guard. It labels containers created
  by the runner and pauses those containers after full I/O PSI remains at or
  above 20% for 20 seconds. It resumes the complete guard-owned container batch
  only after PSI remains at or below 5% for 60 seconds, keeping a job and its
  runner-created step and service containers together.
- The guard records a container as owned only after a successful pause and
  resumes only recorded containers. A crash between the Docker pause and the
  ownership record deliberately leaves that container paused for operator
  review rather than risking the resume of a container paused for another
  reason. Ambiguous pause or resume ownership remains degraded until an operator
  resolves it.
- Runner startup requires a healthy pressure guard. A hard guard failure stops
  the bound runner service so it cannot admit unprotected work; this can
  interrupt job orchestration and requires operator recovery.

## Alternatives Considered

**Keep Kubernetes runners and fix startup scripts** — improves symptoms but keeps
the wrong ownership model. The runner remains a pod that depends on host Docker
and runtime package installation.

**Use a custom runner container image** — acceptable as a temporary mitigation,
but still requires Docker socket mounts and Kubernetes runner lifecycle.

**Run all jobs directly on the host** — rejected for normal CI because it removes
clean per-job environments. Host-level jobs should be explicit exceptions.

**Detect individual games and pause the runner** — rejected for the initial
workstation policy. It couples build admission to compositor- and game-specific
state, while aggregate CPU and memory limits plus low contention weights protect
interactive work regardless of which foreground application creates pressure.

**Set CPU and memory limits on each container independently** — rejected because
two admitted jobs, their service containers, and their step containers could
multiply the intended host budget. A shared parent slice enforces one aggregate
limit across the containers Forgejo Runner creates.

## Consequences

- Runner implementation lives in `nix-config`.
- GitOps removes Kubernetes runner Deployments and related PVCs.
- CI trust improves because host capabilities are declared and checked by NixOS
  instead of discovered after pod startup.
- Docker-capable runners remain trusted infrastructure and must not be exposed to
  untrusted workloads.
- Routine workflows can run on all four native runners through the shared
  `forgejo-docker-primary`, `ubuntu-latest`, and `docker` labels. Excess work
  remains queued when their declared capacities are full.
- Each Kubernetes server-worker contributes one routine-pool slot. This spreads
  eligible work without allowing concurrent runner jobs to amplify local
  resource contention on a cluster member.
- `xyz` contributes two slots within one aggregate resource budget. Builds can
  consume up to half the workstation's CPU and memory, while memory reclaim and
  scheduling weights favor interactive workloads under contention.
- The policy does not yet provide a hard ZFS I/O guarantee or contain nested
  Docker work. Those boundaries require daemon- or storage-level enforcement
  rather than more limits on the runner service process.
- I/O PSI is a host-wide congestion signal, not attribution of pressure to the
  runner. The guard is an emergency circuit breaker scoped to labeled runner
  containers; it does not guarantee an I/O rate, and workflow wall-clock
  timeouts continue while a container is paused.
- Containers started through a job's mounted Docker socket do not automatically
  inherit the runner label and remain outside the pressure guard. Workflows that
  use nested Docker must bound their own resource use.
- Nix-heavy workflows remain Docker-backed. Their verification scripts isolate
  build stages and may clean Nix's fake build home only after positively
  identifying an explicitly opted-in ephemeral job container.
- Runner hosts check filesystem pressure frequently instead of relying only on a
  fixed cleanup schedule. The default policy starts age-filtered build-cache
  pruning at 70% used, permits all unused cache to be pruned at 80% used, aims
  for 40% free, and retains at least 10 GB of BuildKit cache. The existing
  weekly age-based Docker cleanup remains responsible for old unused images.

## Work Items

Nix-config-owned work:

- [x] [alcxyz/nix-config#49](https://git.alc.xyz/alcxyz/nix-config/issues/49)
  implement the native NixOS runner module.
- [x] [alcxyz/nix-config#50](https://git.alc.xyz/alcxyz/nix-config/issues/50)
  deploy the first native Docker-capable runner on `xyz`.
- [x] [alcxyz/nix-config#51](https://git.alc.xyz/alcxyz/nix-config/issues/51)
  decide runner roles for `nux` and `nex`.
- [x] [alcxyz/nix-config#52](https://git.alc.xyz/alcxyz/nix-config/issues/52)
  migrate runner secrets from Kubernetes to SOPS/NixOS.
- [ ] [alcxyz/nix-config#53](https://git.alc.xyz/alcxyz/nix-config/issues/53) add
  rebuild QA guardrails for runner hosts.
- [x] Add `xev` to the primary native Docker-capable runner pool. Completed
  2026-05-31.

GitOps-owned coordination work:

- [x] [alcxyz/gitops#212](https://git.alc.xyz/alcxyz/gitops/issues/212) retarget
  workflows to explicit runner labels.
- [x] [alcxyz/gitops#213](https://git.alc.xyz/alcxyz/gitops/issues/213) remove
  Kubernetes runner deployments after native cutover.
- [ ] [alcxyz/gitops#214](https://git.alc.xyz/alcxyz/gitops/issues/214) add a
  runner capability probe workflow.
- [x] [alcxyz/gitops#215](https://git.alc.xyz/alcxyz/gitops/issues/215) document
  the temporary Kubernetes runner deprecation plan.
