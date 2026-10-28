# ADR-0043: Selective external nix-config pattern adoption

**Status:** Accepted, partially implemented (first-class inventory facts and broader `alc.host` adoption remain)
**Date:** 2026-05-11
**Amended:** 2026-10-28
**History:** [replaced text](archive/0043-selective-external-nix-config-pattern-adoption-history.md)
**Applies to:** `docs/adr/`, `inventory.nix`, `flake/`, `modules/`, `hosts/`, `users/`

## Context

`~/src/clones/emergenmind-config` has several useful operational patterns that
could improve this repository. It also carries heavier framework choices that
would make this repo less explicit if copied wholesale.

This repo already had good local foundations:

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
   `inventory.nix` as the source of truth, and project the selected host's
   inventory into the typed `alc.host` module namespace for both NixOS and
   Home Manager (`modules/shared/host-metadata.nix`). Modules can ask for facts
   like platform, role, k8s role, remote-management posture, gaming posture,
   and operator access without relying only on `specialArgs`.
2. **A small operator command surface.** The `justfile` covers checks,
   formatting, rebuilds, deploys, workspace status, and targeted flake-input
   updates.
3. **Flake checks and pre-commit coverage.** Flake checks cover formatting of all
   Nix files, check-script formatting, shellcheck, and submodule hygiene;
   local pre-commit hooks cover Nix formatting of all Nix files, repository hygiene,
   destroyed-symlink detection, and shellcheck. Checks stay useful locally and
   in CI without forcing a large policy migration in one step.
4. **Generated SSH client entries from inventory.** Inventory facts generate
   normal SSH match blocks for managed hosts. Special Cloudflare, Git, and
   external entries stay explicit.
5. **File-based public key catalogs.** Public SSH keys live outside shared
   NixOS modules, in a private catalog grouped by purpose. The private
   `sshAccessPolicy` module ([ADR-0032](0032-ssh-key-ownership-and-deployment.md))
   owns the catalog and access assignments and supplies concrete account
   membership through standard NixOS options.
6. **Host-local file splitting for large hosts.** Oversized host configs are
   split into local files; `xyz` has `storage.nix` and `gaming.nix` beside its
   `configuration.nix`.
7. **Minimal install/recovery outputs.** Add minimal host configurations only
   when there is a concrete install or recovery workflow, not as an abstract
   framework exercise. None exists yet.
8. **Declarative disk layout evaluation.** Evaluate disko for new hosts and
   reinstalls, but do not migrate existing working storage layouts without a
   host-specific reason. Disko is not adopted yet.

Shared package sets and host metadata live under `modules/shared/`. The Linux
operator Home Manager layer is explicit and carries infrastructure secrets,
Kubernetes credentials, and Forgejo/Grove automation. The common NixOS module
imports the distributed-build client policy from the private
`nixosModules.distributedBuildClientPolicy` output on every NixOS host, and each
host opts in with `alc.distributedBuildClient.enable`, so server roles do not
automatically imply remote-build credentials.

Still to do:

- broader migration of modules from loose `specialArgs` reads to `alc.host`
  facts where that reduces duplication
- first-class inventory facts for operator access, support posture, and
  distributed-build eligibility

Do not adopt:

- broad auto-import patterns such as recursive `scanPaths` for normal host
  imports
- experimental Nix pipe-operator syntax as a repo-wide style
- an external personal framework dependency equivalent to `introdus`
- impermanence as a default posture
- a wholesale directory restructure

### Formatting

`treefmt.toml` holds formatter selection
([#281](https://git.alc.xyz/alcxyz/nix-config/issues/281)). `just fmt`,
`just fmt-check`, the pre-commit formatting hook, and the flake formatting
checks consume that same configuration. All Nix files are covered; shell
coverage remains explicitly listed. Historical formatting is normalized
separately from behavior changes.

### Validation and the private boundary

[ADR-0067](0067-explicit-consumer-and-platform-validation.md) defines the
producer/consumer validation contract used by the public gates.

Host-specific display hardware is supplied through the private boundary, and
the shared desktop role stays independently reusable
([#280](https://git.alc.xyz/alcxyz/nix-config/issues/280)). The common audio,
Bluetooth, and container configuration keeps the accepted baseline in
[ADR-0006](0006-four-tier-module-layering.md). Large host and streaming
modules were extracted under
[#279](https://git.alc.xyz/alcxyz/nix-config/issues/279); the composition that
remains in host files is deliberate.

Named private host modules also supply filesystem device identities and the
workstation network profile. Public hardware composition retains generic
filesystem types and kernel settings; the consumer lock and complete deployment
checks validate the private boundary together.

Private modules are consumed through named `nix-secrets` flake outputs. The
minimum interface required here includes `nixosModules.nixboxClientPrivate`,
`nixosModules.operatorLogin`, `homeManagerModules.linuxOperator`, and
`homeManagerModules.darwinOperator`.
Optional bootstrap tooling is imported only by the explicit Linux and Darwin
operator compositions, so appliance and family profiles do not carry unused
operator option schemas.

There is no `operatorLogin` availability guard: private revisions that lack it
also predate the required client export. Guards inside the private operator
modules remain intentional: they allow the shared private defaults to compose
with public profiles that do not import every optional service module.
Required named interfaces above are unguarded and fail during evaluation when
absent.

The xyz storage split follows the same pattern. `hosts/xyz/storage.nix` owns
the generic host-local assembly and declares required typed policy fields
without public defaults. The private `xyzStoragePolicy` flake output composes
the existing unlock/bootstrap and mergerfs modules, supplies those fields, and
owns sensitive storage, backup, and export policy. The public host keeps one
explicit import for each side of that boundary.

### Hyprland sources

The `alc` workstation profile uses the immutable Lua configuration; its
Hyprlang files, host fragment and legacy-only parity conditions are retired,
while the Lua behavior assertions and helper-script contracts are retained.
Keeping an unconsumed second configuration would require duplicate edits
without validating the configuration that the declared session actually uses.

This is a profile-specific retirement, not removal of shared legacy support.
The `madsil` profile still consumes its own Hyprlang source through the existing
module. Removing the shared option, activation path or legacy key helper would
break that consumer and requires a separate migration. The shared live-migration
mechanism remains available for profiles that retain both source formats; it is
not a rollback contract for the retired `alc` files.

Keep desktop helper composition and policy binding in the workstation module,
with ordinary shell bodies in adjacent sources. Replacing helper languages is
decided separately: [ADR-0095](0095-bounded-workspace-sync-go-pilot.md) limits
Go to one workspace-sync pilot. Source cleanup neither activates a compositor
configuration nor substitutes for runtime qualification.

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

The repo keeps its shape, with stronger guardrails.

Host-related modules can become less ad hoc because they can consume typed
`alc.host` facts instead of parallel role checks or loose arguments.

The operator workflow is easier to repeat on new machines.

Explicit imports remain the default for host composition. This keeps security,
storage, k3s, and remote-management behavior reviewable from each host file.
