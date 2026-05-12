# ADR-0043 through ADR-0047 merge plan

This worktree contains several independent changes that should be reviewed as
separate PRs or cherry-picked commits instead of merged as one large branch.

## Merge Sequence

1. **Host workflow primitives**
   - Branch: `pr/adr-host-workflow`
   - PR: [#70](https://git.alc.xyz/alcxyz/nix-config/pulls/70), merged
   - Commits: `4fca257`, `a88e37d`, `460e558`
   - Scope: ADR-0043/0044/0046 implementation scaffolding, host metadata,
     package set ownership, operator Home Manager layer, checks, justfile, SSH
     key catalog, docs status updates.
   - Validation: `nix flake check --keep-going`, `nix develop -c just fmt-check`.

2. **Bullet Kubernetes helpers**
   - Branch: `pr/bullet-kube-helpers`
   - PR: [#71](https://git.alc.xyz/alcxyz/nix-config/pulls/71), merged
   - Commit: `99bc6cc`
   - Scope: `bullet-connect`, `bullet-kube`, `bullet-proxy`, switcher-visible
     kubeconfig files, ADR-0031/README docs.
   - Validation: Home Manager evaluation for mac and a shellcheck pass through
     flake checks.

3. **Kubernetes API VIP**
   - Branch: `pr/k8s-api-vip`
   - PR: [#72](https://git.alc.xyz/alcxyz/nix-config/pulls/72), merged
   - Commits: `e431f3b`, `6718010`
   - Scope: ADR-0047, keepalived VIP module, k3s TLS SAN support, host wiring
     for nux/nex/rpi0/xyz.
   - Validation: all NixOS configs evaluate, then deploy in the order described
     in ADR-0047.

4. **nix-secrets lock update**
   - Branch: `pr/nix-secrets-lock-refresh`
   - PR: [#73](https://git.alc.xyz/alcxyz/nix-config/pulls/73), merged
   - Commits: `0828e31`, `5f61e0a`
   - Scope: secret material needed by the host/deploy changes.
   - Validation: evaluate all affected hosts after updating the lock.

5. **Local deploy orchestration**
   - Branch: `pr/local-deploy-here`
   - PR: [#74](https://git.alc.xyz/alcxyz/nix-config/pulls/74), merged
   - Commit: `515976e`
   - Scope: local `nix-deploy` wrapper override, `deploy --here`, ADR-0009
     amendment.
   - Validation: wrapper package build, `deploy --help`, flake checks.

6. **mac Linux-builder bootstrap**
   - Branch: `pr/mac-linux-builder`
   - Base: current `dev` after PRs #70-#74
   - Commit: branch tip
   - Scope: `hosts/mac/configuration.nix` enabling nix-darwin's stock
     `nix.linux-builder`, plus README/ADR updates.
   - Validation: `nix build .#darwinConfigurations.mac.system --no-link`; after
     activation, verify `nix show-config` lists `linux-builder` and build rpi0's
     toplevel from mac.

## Issue Backlog

Created issues for the work that should not be hidden inside the PRs:

- [#75](https://git.alc.xyz/alcxyz/nix-config/issues/75) Track `xev` host
  skeleton, secrets, first deploy, k3s agent join, metrics, and Longhorn
  prerequisite validation from ADR-0045.
- [#76](https://git.alc.xyz/alcxyz/nix-config/issues/76) Track `xps`
  workstation skeleton and separate Kubernetes participation decision from
  ADR-0045.
- [#77](https://git.alc.xyz/alcxyz/nix-config/issues/77) Track family gaming
  laptop host skeleton, family user profile, support-scoped secrets, and
  Netbird isolation policy from ADR-0046.
- [#78](https://git.alc.xyz/alcxyz/nix-config/issues/78) Track mac
  x86_64-linux builder support for nux/nex after the initial aarch64-linux
  builder is active.
- [#79](https://git.alc.xyz/alcxyz/nix-config/issues/79) Decide whether mac is
  an emergency build coordinator only or a normal documented fallback.
- [#80](https://git.alc.xyz/alcxyz/nix-config/issues/80) Retire the fallback
  path or lower its priority when xyz returns.
- [#81](https://git.alc.xyz/alcxyz/nix-config/issues/81) Track whether
  `nix-deploy` should move back to `nix-packages` after the local wrapper
  behavior has been QA'd.

## Cherry-pick Notes

Cherry-pick or merge in dependency order. The host workflow primitives should
land before the API VIP, local deploy orchestration, or mac Linux-builder
branches because those branches rely on the shared package set and
format/check coverage changes. The Bullet helpers and nix-secrets lock refresh
are independent from that stack and can be reviewed separately. Keep the lock
update separate so it can be retried or refreshed without touching code.
