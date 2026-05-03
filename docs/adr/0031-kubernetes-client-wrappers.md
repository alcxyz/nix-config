# ADR-0031: Kubernetes client wrappers with per-command kubeconfig

**Status:** Accepted
**Date:** 2026-05-03
**Applies to:** `modules/home-manager/programs/kubernetes/`, `users/alc/*`, `modules/nixos/common/pkgsets.nix`

## Context

Cluster access uses a kubeconfig decrypted from `nix-secrets` via sops-nix.
Historically Home Manager exported `KUBECONFIG` as a user session variable.
That worked for normal interactive shells, but it was brittle for:

- plain shells that did not inherit Home Manager session variables
- agent subprocesses
- GUI-launched tools
- tools that need cluster access indirectly, such as `leantime-tidy`

The secret itself was already handled correctly as a strict-permission
sops-nix file. The weak point was relying on broad ambient environment
propagation to make client tools discover it.

## Decision

Manage Kubernetes client access through a Home Manager module:

`modules/home-manager/programs/kubernetes/default.nix`

The module installs wrappers for Kubernetes-aware commands. Each wrapper sets
`KUBECONFIG` to the sops-nix kubeconfig path only when `KUBECONFIG` is not
already set, then execs the real command.

Managed wrappers currently include:

- `kubectl`
- `flux`
- `helm`
- `k9s`
- selected higher-level tools, currently `leantime-tidy` on `xyz`

`kubeswitch` is installed unchanged because it manages kubeconfig state itself.

The module also owns the Kubernetes shell aliases (`k`, `kg`, `kl`, etc.).
Raw Kubernetes client binaries were removed from the shared `hm.k8s` package
set so command names are owned by the wrappers and Home Manager does not
collide on duplicate `bin/*` entries.

The global `KUBECONFIG` session variable is no longer exported by default.
The module still exposes `exportSessionVariable` as an opt-in escape hatch.

## Alternatives Considered

**Continue exporting `KUBECONFIG` globally:** Rejected. It depends on session
environment propagation and fails in exactly the contexts where debugging and
automation often run.

**Put this in the NixOS k3s module:** Rejected. The NixOS k3s module configures
server-side cluster participation. This problem is user-level client access and
applies across Linux, Darwin, workstations, and tools that talk to the cluster
remotely.

**Only document explicit `KUBECONFIG=... kubectl ...` commands:** Rejected.
That is reliable but noisy, easy to forget, and does not help tools that invoke
`kubectl` internally.

**Copy the kubeconfig into a conventional user path like `~/.kube/config`:**
Rejected. The existing sops-nix secret path already provides the right
permissions and lifecycle. Copying would introduce another credential surface
that can drift or outlive the decrypted secret.

## Consequences

- `kubectl`, `flux`, `helm`, and wrapped tools work from plain shells and agent
  subprocesses without inherited session variables.
- Cluster credentials are scoped to Kubernetes-aware commands rather than every
  child process in the user session.
- Users can still override `KUBECONFIG` explicitly for alternate clusters.
- Kubernetes package ownership is centralized in the Home Manager module rather
  than the shared package set.
- New Kubernetes-aware tools should be added to this module when they need the
  managed kubeconfig path.
