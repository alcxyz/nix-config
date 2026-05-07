# ADR-0041: Native Forgejo Actions runners

**Status:** Implemented
**Date:** 2026-05-07
**Applies to:** Forgejo Actions runner services, `hosts/xyz`, `hosts/nux`, `hosts/nex`

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

Run native Docker-capable runners on `xyz`, `nux`, and `nex`. Normal jobs use
Docker-backed labels; `nux-deploy:host` is retained as the explicit trusted
host-level exception.

## Required Properties

- No package installation during service startup.
- No runner registration if required checks fail.
- Docker-capable labels only on hosts intentionally allowed to expose the Docker
  socket to CI jobs.
- Normal CI jobs use container-backed Forgejo labels, preserving clean job
  environments.
- Host-level labels are explicit and used only for trusted infrastructure
  workflows.

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

GitOps-owned coordination work:

- [ ] [alcxyz/gitops#212](https://git.alc.xyz/alcxyz/gitops/issues/212) retarget
  workflows to explicit runner labels.
- [x] [alcxyz/gitops#213](https://git.alc.xyz/alcxyz/gitops/issues/213) remove
  Kubernetes runner deployments after native cutover.
- [ ] [alcxyz/gitops#214](https://git.alc.xyz/alcxyz/gitops/issues/214) add a
  runner capability probe workflow.
- [x] [alcxyz/gitops#215](https://git.alc.xyz/alcxyz/gitops/issues/215) document
  the temporary Kubernetes runner deprecation plan.
