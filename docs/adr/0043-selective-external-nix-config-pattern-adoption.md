# ADR-0043: Selective external nix-config pattern adoption

**Status:** Accepted (partially implemented 2026-05-12)
**Date:** 2026-05-11
**Applies to:** `docs/adr/`, `inventory.nix`, `flake/`, `modules/`, `hosts/`, `users/`

## Context

`~/src/clones/emergenmind-config` has several useful operational patterns that
could improve this repository. It also carries heavier framework choices that
would make this repo less explicit if copied wholesale.

This repo already has good local foundations:

- `flake-parts` output separation under `flake/`
- `inventory.nix` as host source of truth
- explicit four-tier module layering
- ADRs for architecture and operational decisions
- focused service modules for k3s, Netbird, ZFS auto-unlock, Forgejo runners,
  NFS, UniFi, Pi-hole, Kubernetes wrappers, and workspace bootstrap

The useful external concepts are mostly validation, bootstrap, and operator
workflow patterns rather than direct module reuse.

## Decision

Adopt selected concepts from the external config incrementally, while keeping
this repository's explicit import and inventory-first model.

Adopt:

1. **Typed host metadata exposed through the module system.** Keep
   `inventory.nix` as the source of truth, but project the selected host's
   inventory into a typed module namespace such as `alc.host`. Modules should
   be able to ask for facts like platform, role, k8s role, remote-management
   posture, gaming posture, and operator access without relying only on
   `specialArgs`.
2. **A small operator command surface.** Add a `justfile` or equivalent wrapper
   for common tasks: format, check, rebuild, deploy, Home Manager switch,
   workspace status, and targeted flake-input updates.
3. **Flake checks and pre-commit coverage.** Add formatting, shell formatting,
   shell linting where practical, destroyed-symlink detection, and a submodule
   guard. Checks should be useful locally and in CI without forcing a large
   policy migration in one step.
4. **Generated SSH client entries from inventory.** Use inventory facts to
   generate normal SSH match blocks for managed hosts. Keep special entries,
   Cloudflare fallback behavior, and one-off external machines explicit.
5. **File-based public key catalogs.** Move hardcoded public SSH keys out of
   shared NixOS modules into files grouped by purpose, then import those files
   into login, mobile, operator, and distributed-build key lists.
6. **Host-local file splitting for large hosts.** Split oversized host configs,
   especially `xyz`, into local files such as `storage.nix`, `services.nix`,
   `virtualisation.nix`, `networking.nix`, and `users.nix`.
7. **Minimal install/recovery outputs.** Add minimal host configurations only
   when there is a concrete install or recovery workflow, not as an abstract
   framework exercise.
8. **Declarative disk layout evaluation.** Evaluate disko for new hosts and
   reinstalls, but do not migrate existing working storage layouts without a
   host-specific reason.

## Implementation Status

Implemented in `feat/adr-0043-0046-implementation`:

- typed host metadata projection through `alc.host` for both NixOS and Home
  Manager
- `justfile` command surface for checks, formatting, rebuilds, deploys,
  workspace status, and input updates
- flake checks for targeted Nix formatting, check-script formatting,
  shellcheck, and submodule hygiene
- local pre-commit hooks for targeted Nix formatting, repository hygiene,
  destroyed symlink detection, and shellcheck
- inventory-generated SSH client match blocks for managed hosts, while keeping
  special Cloudflare, Git, and external entries explicit
- behavior-preserving public SSH key catalog in
  `modules/nixos/common/ssh-keys.nix`

Still pending:

- splitting oversized host-local files such as `hosts/xyz/configuration.nix`
- install or recovery outputs for hosts that need them
- any disko adoption for new hosts or reinstalls
- broader migration of modules from loose `specialArgs` reads to `alc.host`
  facts where that reduces duplication

Do not adopt:

- broad auto-import patterns such as recursive `scanPaths` for normal host
  imports
- experimental Nix pipe-operator syntax as a repo-wide style
- an external personal framework dependency equivalent to `introdus`
- impermanence as a default posture
- a wholesale directory restructure

## Alternatives Considered

**Copy the external structure directly** - rejected. It would replace explicit
local decisions with a larger framework and would make host composition less
visible.

**Ignore the external config entirely** - rejected. The comparison found
practical improvements around validation, checks, bootstrap, and generated
metadata.

**Move all host metadata into NixOS module options and remove `inventory.nix`** -
rejected. `inventory.nix` is already documented as the source of truth and is a
good flake-level data model. The useful change is typed projection into module
config, not replacing the inventory.

## Consequences

The repo keeps its current shape, but gains stronger guardrails.

Host-related modules can become less ad hoc because they can consume typed
`alc.host` facts instead of parallel role checks or loose arguments.

The operator workflow becomes easier to repeat on new machines.

The first implementation should be small: checks, a command surface, and typed
host metadata before broader host refactors.

Explicit imports remain the default for host composition. This keeps security,
storage, k3s, and remote-management behavior reviewable from each host file.
