# ADR-0041: Native Forgejo Actions runners

**Status:** Implemented (amended 2026-08-12: pressure-aware build-cache lifecycle)
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

The default runner priority is represented with labels:

- `forgejo-docker-primary` is exposed only by `xyz` and `xev`.
- `forgejo-docker-secondary` is exposed by `nux` and `nex` for deliberate
  fallback or diagnostics.
- `ubuntu-latest` and `docker` remain compatibility labels only on the primary
  pool.
- host-specific Docker labels (`xyz`, `xev`, `nux`, `nex`) remain available for
  workflows that intentionally need one host.

## Required Properties

- No package installation during service startup.
- No runner registration if required checks fail.
- Docker-capable labels only on hosts intentionally allowed to expose the Docker
  socket to CI jobs.
- Normal CI jobs use container-backed Forgejo labels, preserving clean job
  environments.
- Host-level labels are explicit and used only for trusted infrastructure
  workflows.
- Primary and secondary scheduling intent is visible in labels instead of hidden
  in runner capacity assumptions.
- Build cache is preserved while the host filesystem is healthy. Under moderate
  pressure, only cache unused for the configured grace period is eligible for
  removal; under critical pressure, all unused cache may be reclaimed. Running
  containers, images needed by containers, and volumes are outside this policy.

## Alternatives Considered

**Keep Kubernetes runners and fix startup scripts** — improves symptoms but keeps
the wrong ownership model. The runner remains a pod that depends on host Docker
and runtime package installation.

**Use a custom runner container image** — acceptable as a temporary mitigation,
but still requires Docker socket mounts and Kubernetes runner lifecycle.

**Run all jobs directly on the host** — rejected for normal CI because it removes
clean per-job environments. Host-level jobs should be explicit exceptions.

## Consequences

- Runner implementation lives in `nix-config`.
- GitOps removes Kubernetes runner Deployments and related PVCs.
- CI trust improves because host capabilities are declared and checked by NixOS
  instead of discovered after pod startup.
- Docker-capable runners remain trusted infrastructure and must not be exposed to
  untrusted workloads.
- Routine GitOps workflows target the primary `xyz`/`xev` runner pool. `nux`
  and `nex` are kept available for explicit fallback work without taking normal
  jobs from the larger hosts.
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
