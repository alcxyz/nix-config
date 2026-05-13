# ADR-0031: Kubernetes client wrappers with merged per-command kubeconfig

**Status:** Accepted
**Date:** 2026-05-03
**Applies to:** `modules/home-manager/programs/kubernetes/`, `users/alc/*`, `modules/shared/pkgsets.nix`

## Context

Cluster access uses a kubeconfig decrypted from `nix-secrets` via sops-nix.
Local development clusters and work clusters can also leave kubeconfigs under
`~/.kube`, including files written by interactive scripts. Historically Home
Manager exported one `KUBECONFIG` as a user session variable. That worked for
normal interactive shells, but it was brittle for:

- plain shells that did not inherit Home Manager session variables
- agent subprocesses
- GUI-launched tools
- tools that need cluster access indirectly, such as `leantime-tidy`

The secret itself was already handled correctly as a strict-permission
sops-nix file. The weak points were relying on broad ambient environment
propagation to make client tools discover it, and treating the secret as the
only usable kubeconfig.

## Decision

Manage Kubernetes client access through a Home Manager module:

`modules/home-manager/programs/kubernetes/default.nix`

The module installs wrappers for Kubernetes-aware commands. Each wrapper sets
`KUBECONFIG` only when it is not already set, then execs the real command.

The generated `KUBECONFIG` is a merge of:

- a writable Home Manager-created current-context file
- the sops-nix kubeconfig
- optional extra kubeconfig files that exist on disk

The writable current-context file is first in the list. That lets
`kubectl config use-context ...` persist the selected context without writing
into the sops-nix secret.

Managed wrappers currently include:

- `kubectl`
- `flux`
- `helm`
- `k9s`
- `kdash`
- `switcher`
- selected higher-level tools, currently `leantime-tidy` on `xyz`

`switcher` and `kc` both persist context selections into the managed
current-context file. `kc <context>` first checks the merged kubectl context
list for an exact match so it does not depend on switcher cache state, then
falls back to `switcher set-context` for fuzzy or interactive selection. Plain
`switcher` wraps upstream `switcher`, parses the selected `config-path,context`
response, and then runs `kubectl config use-context`. `kns` uses
`kubectl config set-context --current --namespace` for the same reason.
Upstream `switcher ns` does not support multi-file `KUBECONFIG`.

The module also owns the Kubernetes shell aliases (`k`, `kg`, `kl`, etc.).
Raw Kubernetes client binaries were removed from the shared `hm.k8s` package
set so command names are owned by the wrappers and Home Manager does not
collide on duplicate `bin/*` entries.

For Bullet work clusters, the module can also install managed helper commands
from the private `bn-bootstrap` flake:

- `bullet-connect` selects the Bullet Azure subscription and opens an Azure
  Bastion SSH session to the environment management VM.
- `bullet-proxy` selects the same environment, opens an Azure Bastion tunnel,
  and optionally starts a local SOCKS5 proxy through that tunnel.
- `bullet-kube` fetches AKS credentials into dedicated per-environment files
  (`~/.kube/bullet-sandbox-config`, `~/.kube/bullet-staging-config`,
  `~/.kube/bullet-prod-config`, `~/.kube/bullet-infra-config`) and converts
  them to Azure CLI exec auth with `kubelogin`.

The script implementation and Bullet-specific access documentation live in
`bn-bootstrap`. This module only installs the package, exports SOPS-backed
Azure identifier file paths, and merges the resulting kubeconfig files.

Those Bullet kubeconfig paths are part of the managed kubeconfig merge when the
Bullet helpers are enabled. This means `switcher` can list and select the
contexts after `bullet-kube` has materialized the files, while network access to
the private AKS API still depends on the Bullet management path.

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

**Copy the secret kubeconfig into a conventional user path like
`~/.kube/config`:** Rejected. The existing sops-nix secret path already
provides the right permissions and lifecycle. Copying would introduce another
credential surface that can drift or outlive the decrypted secret.

## Consequences

- `kubectl`, `flux`, `helm`, and wrapped tools work from plain shells and agent
  subprocesses without inherited session variables.
- Local kubeconfigs, such as minikube, and script-created kubeconfigs can be
  part of the same merged client view.
- Bullet work kubeconfigs are written to stable, named files instead of being
  merged into `~/.kube/config`, so they are visible to `switcher` without
  polluting the default kubeconfig.
- Cluster credentials are scoped to Kubernetes-aware commands rather than every
  child process in the user session.
- Users can still override `KUBECONFIG` explicitly for one-off alternate
  cluster sets.
- Kubernetes package ownership is centralized in the Home Manager module rather
  than the shared package set.
- New Kubernetes-aware tools should be added to this module when they need the
  managed kubeconfig path.
