# nix-config

Multi-host NixOS, nix-darwin, and Home Manager flake managing workstations, servers, and a Mac across three architectures.

## Maintainer QA

Paperflow, Grove, Canopy, DankSession, and the maintained DMS plugins use
explicit `dev` inputs, pinned to exact commits in `flake.lock`. The DMS bundle
stays the source interface; local input overrides select plugin development
branches without changing the public bundle's release defaults. Widget files
and their helpers use the same source revision.

From this checkout, run `qaup` to refresh only those projects, inspect
the lockfile changes, then use `nxsw` and/or `hmsw` for the relevant system or
Home Manager configuration. Rebuild commands apply the lockfile; they do not
fetch new branch heads automatically. Committing a lockfile records the exact
combination under QA and keeps rollback reproducible.

The `qaup` shell shortcut needs no flags or development shell. After first
adding it to your configuration, run `hmsw` once and open a new terminal to load
it. The existing `just qa-update` recipe remains available for development.

Develop changes on feature branches, integrate them into `dev` for QA, and
promote approved work to each project's `main` for official releases. Neither
`qaup` nor a rebuild promotes branches or creates releases. Uncommitted
source edits are not fetched from GitHub: publish them to `dev` first.

Upstream dependencies, including DMS itself and nixpkgs, keep their existing
pinning policies. WorldClock, DankCalculator, and DMS-Screenshot are upstream
forks, not maintained projects; they retain the bundle's main pins and are not
explicitly refreshed by the QA command. See
[ADR-0069](docs/adr/0069-maintained-project-dev-qa.md).

## Hosts

The host names, systems, and role identifiers below match
[`inventory.nix`](inventory.nix). Role defaults are defined in its `roles` map.

| Host | System | Inventory role |
|------|--------|----------------|
| mac | aarch64-darwin | mac |
| madsil | x86_64-linux | family-gaming |
| nex | x86_64-linux | nuc |
| nux | x86_64-linux | nuc |
| rpi0 | aarch64-linux | embedded |
| rpi1 | aarch64-linux | embedded |
| rpi2 | aarch64-linux | embedded |
| rpi3 | aarch64-linux | embedded |
| xev | x86_64-linux | k8s-worker |
| xps | x86_64-linux | laptop-workstation |
| xyz | x86_64-linux | workstation |

See [ADR-0044](docs/adr/0044-host-inventory-role-model-for-new-machines.md),
[ADR-0045](docs/adr/0045-xev-and-xps-kubernetes-node-onboarding.md), and
[ADR-0046](docs/adr/0046-remotely-managed-family-gaming-laptop.md).

### XPS media center

XPS also provides a controller-first couch session for browsing, Moonlight,
dynamic TV layouts, simultaneous TV audio, phone input, and a merged DMS shell.
See the [XPS media-center guide](docs/xps-media-center.md) for controller and
keyboard shortcuts, display modes, audio choices, and the on-screen help
overlay.

### Compact Nixbox clients

The reusable compact client profile turns smaller NixOS hosts into
controller-first Moonlight endpoints without carrying the XPS workbench
configuration. See the [compact Nixbox client guide](docs/nixbox-client.md) for
the shared session, input, display, audio, and presentation boundaries.

### Visual reports

Standalone, summary-first HTML reports complement the Markdown archive for
interactive test review. See [the visual report guide](docs/reports/README.md)
and open a report locally with `reportcraft`; use its explicit `--lan` mode
only when another machine needs temporary access.

## Repository layout

```
inventory.nix                      # Canonical host facts: system, platform, role, k8s role
flake.nix                          # Inputs and flake-parts entry point
flake/
  core.nix                         # Inventory, supported systems, shared package instances
  pkgs.nix                         # Package overlays and local package overrides
  hosts/                           # NixOS, nix-darwin, and Home Manager output construction
  per-system.nix                   # Development shell, packages, and check composition
  checks/                          # Explicit check definitions and evaluation helpers
justfile                           # Operator command surface for checks, rebuilds, deploys
.pre-commit-config.yaml            # Local repository hygiene hooks
scripts/checks/                    # Shell checks used by pre-commit and flake checks
hosts/
  {xyz,nux,nex,xev,xps,madsil,rpi0,rpi1,rpi2,rpi3}/
    configuration.nix              # Host-specific NixOS config
    hardware-configuration.nix     # Generated hardware config
  mac/
    configuration.nix              # nix-darwin system config
modules/
  shared/
    host-metadata.nix              # Typed alc.host projection from inventory
    pkgsets.nix                    # Centralized package sets by role
  nixos/
    common/
      default.nix                  # Shared across all NixOS hosts
      distributed-build-client.nix # Optional distributed builds through xyz
      ssh-keys.nix                 # Public SSH key catalog grouped by purpose
      desktop.nix                  # Workstation layer (xyz)
      server.nix                   # Headless system package and X server defaults
    hardware/
      amd.nix                      # AMD GPU/CPU
      nvidia.nix                   # Nvidia GPU (legacy_580)
    services/
      nfs/                         # NFS server + Avahi discovery
      plex/                        # Plex media (Docker)
      stash/                       # Stash (Docker)
      torrent/                     # qBittorrent (Docker)
    virtualisation/
      kvm/
        default.nix                # Base KVM/libvirtd
        gpu-passthrough.nix        # Dynamic GPU passthrough hooks
  home-manager/
    shell/                         # Nushell, zsh, bash, starship
    programs/
      ai/                          # AI tools (claude-code, opencode, etc.)
      git/                         # Git config + SSH signing
      ssh/                         # SSH client config
      hyprland/                    # Hyprland + GTK theming
      foot/                        # Foot terminal
      rclone/cloud-sync.nix        # Google Drive + Dropbox sync
    services/
      paperflow/                   # File organizer + Paperless ingest (cross-platform)
      dms/                         # DankMaterialShell desktop shell
users/alc/
  common.nix                       # Shared Home Manager config (all platforms)
  linux/
    common.nix                     # Shared Linux HM config, no operator secrets
    operator.nix                   # alc Linux operator layer
    xyz.nix                        # xyz-specific HM config
    nux.nix                        # nux-specific HM config
    nex.nix                        # nex-specific HM config
    rpi0.nix                       # rpi0-specific HM config
  darwin/
    mac.nix                        # macOS-specific HM config
  configs/                         # Dotfiles symlinked into place
users/madsil/                      # Family user Home Manager profile and dotfiles
```

## How it fits together

**Layered configuration** — each host composes from shared layers:

```
hosts/xyz/configuration.nix
  imports common/default.nix       (all hosts)
  imports common/desktop.nix       (workstations)
  imports hardware/{amd,nvidia}.nix
  imports services/{nfs,plex,...}
  imports virtualisation/kvm/*

users/alc/linux/xyz.nix
  imports users/alc/linux/operator.nix
    imports users/alc/linux/common.nix
    imports users/alc/common.nix   (all platforms)
  imports modules/home-manager/programs/*
  imports modules/home-manager/services/*
```

**Inventory** (`inventory.nix`) is the source of truth for host architecture,
platform, machine role, package role, workspace profiles, and k8s role.
The `flake/` output modules, NixOS modules, and Home Manager modules consume
inventory data instead of carrying separate host-role maps.

Inventory is also projected into a typed module namespace as `alc.host` for
both NixOS and Home Manager. Modules can read host facts without recreating
parallel maps or branching directly on host names:

```nix
config.alc.host.name
config.alc.host.role
config.alc.host.aliases
config.alc.host.k8s.enabled
config.alc.host.k8s.labels
config.alc.host.k8s.taints
```

The projection is intentionally derived from `inventory.nix`; it is not a
second source of truth.

**Package sets** ([`modules/shared/pkgsets.nix`](modules/shared/pkgsets.nix))
define role-based groups. Host files should use the package set selected by
inventory instead of hard-coding the role:

```nix
home.packages = pkgsets.home.${hostRole.homePackageSet};
```

**Workspace bootstrap** (`modules/home-manager/workspace/`) declares the
`~/src` repo catalog and selects repos from inventory workspace profiles.
Home Manager creates the standard directory skeleton and installs
`workspace-sync`, which is intentionally conservative:

```sh
workspace-sync --status  # show existing/missing declared repos
workspace-sync           # clone missing repos only
```

`workspace-sync` never deletes, pulls, resets, cleans, or overwrites existing
paths. Existing git repositories are skipped, and existing non-git paths are
reported and left untouched.

## Related repositories

| Repo | Purpose |
|------|---------|
| [nix-packages](https://git.alc.xyz/alcxyz/nix-packages) | Custom Nix packages. Selectively imported via `flake/pkgs.nix` |
| [nix-secrets](https://git.alc.xyz/alcxyz/nix-secrets) (private) | Private infrastructure material: SOPS data, runbooks, and private integration modules |

**nix-packages** exports per-platform packages. The filtered overlay in
[`flake/pkgs.nix`](flake/pkgs.nix) selects the packages consumed here, alongside
explicit local overrides and additional package inputs. Role-based package
selection belongs to [`modules/shared/pkgsets.nix`](modules/shared/pkgsets.nix).

**nix-secrets** stores private infrastructure material consumed by this flake,
including age-encrypted YAML files decrypted at build/activation time via
sops-nix:

```
nix-secrets/
  shared/secrets.yaml          # Shared across all hosts
  hosts/{xyz,nux,rpi0,mac}/
    secrets.yaml               # Per-host secrets
```

## Key features

- **Cross-platform** — NixOS + nix-darwin + Home Manager from one flake
- **Distributed builds** — nux, nex, and rpi0 can offload builds to xev first,
  then xyz. If both remote builders are unavailable, hosts fall back to local
  builds where the target system is supported. mac remains an emergency deploy
  operator through its nix-darwin Linux builder.
- **Forgejo Actions runners** — primary Docker-backed CI labels run on xyz and
  xev; nux and nex keep secondary and host-specific labels for deliberate
  fallback work.
- **Encrypted storage** — Host storage integration with private bootstrap and recovery runbooks
- **GPU passthrough** — Dynamic nvidia bind/unbind via libvirt hooks. Containers (steam, stash) stop/start automatically
- **NFS + Avahi** — File sharing with Bonjour/Finder discovery, per-IP firewall rules
- **Documents pipeline** — inotify/fswatch file organizer + Paperless-ngx ingest (API on macOS, filesystem on Linux)
- **Private material boundary** — sops-nix wiring in public config, private details in nix-secrets

## Common commands

```bash
# Enter the dev shell when host tools such as just are not already installed
nix develop

# List available repo tasks
just

# Run the normal QA gate
just check

# Check all Nix files and the shell paths selected by treefmt.toml
just fmt-check

# Run local pre-commit hooks (formatting checks cover the whole repository)
just pre-commit

# Run repository hygiene checks
just hygiene

# Explicitly retain 10 system/Home Manager generations, then run capped GC
just gc

# Run the same maintenance remotely through the managed SSH host configuration
just gc nux

# Rebuild NixOS
just rebuild xyz

# Rebuild Home Manager
just home xyz

# Rebuild macOS
just darwin mac

# Deploy from the current machine instead of requiring xyz as the operator
deploy --here --nixos rpi0
deploy --here --all

# Skip the SSH availability preflight only when intentionally bootstrapping/debugging
deploy --no-preflight --nixos rpi0

# Make --all abort instead of skipping unreachable remote hosts
deploy --all --fail-unreachable

# Update flake inputs
just update

# Update a single input
just update nix-packages
```

Automatic maintenance keeps ordinary GC capped at 10 GiB per run. Before that
GC, guarded retention checks the system and managed user's profiles. It prunes
profiles back to 10 generations only when a profile exceeds 20 generations or
the Nix filesystem has less than 15% free, and only after validating every
current profile closure. `just gc [host]` remains the explicit override.

The flake also exposes repository checks, so `nix flake check --keep-going`
remains the direct CI-style command. Its configuration evaluation check forces
all exported NixOS systems, Home Manager activation packages, and Darwin
systems, including aliases and non-native platforms. This validates their
derivations without building complete host closures.

Formatter commands share the selection in `treefmt.toml`: all Nix files and
explicitly listed shell paths. Historical Nix formatting has been normalized.

## Kubernetes client access

The generic Home Manager Kubernetes module installs client wrappers that set a
composed `KUBECONFIG` for each command while preserving a caller-supplied value.
The composition supports a writable current-context file, a configured primary
kubeconfig, and optional additional kubeconfigs that are included when
readable. This avoids requiring a global credential environment for shells,
GUI sessions, and unrelated subprocesses.

See [ADR-0031](docs/adr/0031-kubernetes-client-wrappers.md) for the public
interface and command behavior. Private operator modules provide concrete
credential locations, contexts, and engagement-specific integrations; their
operational checks and recovery procedures live in the private `nix-secrets`
Kubernetes runbooks.
