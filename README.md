# nix-config

Multi-host NixOS, nix-darwin, and Home Manager flake managing workstations, servers, and a Mac across three architectures.

## Hosts

| Host | System | Role |
|------|--------|------|
| xyz | x86_64-linux | Main workstation. Hyprland desktop, GPU passthrough, Docker services, ZFS pools |
| nux | x86_64-linux | Server. Offloads builds to xyz; mac can orchestrate deploys while xyz is unavailable |
| nex | x86_64-linux | NUC k3s server + stable workload host |
| xev | x86_64-linux | k3s server + stable workload host with Longhorn storage and primary Forgejo runner capacity |
| xps | x86_64-linux | Dell XPS workstation; Kubernetes participation deferred until wired networking is reliable |
| rpi0 | aarch64-linux | Rock Pi 4. Primary host-native DNS/Pi-hole; kept outside k3s |
| rpi1 | aarch64-linux | Raspberry Pi 3B+ direct-DRM Moonlight appliance and backup host-native DNS/Pi-hole |
| rpi2 | aarch64-linux | Raspberry Pi 3B+ direct-DRM Moonlight appliance |
| rpi3 | aarch64-linux | Raspberry Pi 3B+ direct-DRM Moonlight appliance |
| mac | aarch64-darwin | MacBook. nix-darwin + Home Manager + bootstrapped aarch64 Linux builder |

Planned hosts are documented before they are added to inventory:

- family gaming laptop - lower-trust remotely supported desktop for a separate
  family user, with Heroic Launcher and isolated Netbird access.

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
flake.nix                          # Entry point — overlays, configs derived from inventory
justfile                           # Operator command surface for checks, rebuilds, deploys
.pre-commit-config.yaml            # Local repository hygiene hooks
scripts/checks/                    # Shell checks used by pre-commit and flake checks
hosts/
  {xyz,nux,nex,xev,xps,rpi0,rpi1,rpi2,rpi3}/
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
      wofi/                        # App launcher
    services/
      documents/                   # File organizer + Paperless ingest (cross-platform)
      dms/                         # DankMaterialShell greeter
    secrets/
      ssh-keys.nix                 # SSH key deployment via sops
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
platform, machine role, package role, future workspace profile, and k8s role.
`flake.nix`, NixOS modules, and Home Manager modules consume inventory data
instead of carrying separate host-role maps.

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

**Package sets** (`pkgsets.nix`) define role-based groups. Host files should use
the package set selected by inventory instead of hard-coding the role:

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
| [nix-packages](https://github.com/alcxyz/nix-packages) | Custom Nix packages. Selectively imported via overlay in `flake.nix` |
| [nix-secrets](https://github.com/alcxyz/nix-secrets) (private) | Private infrastructure material: SOPS data, runbooks, and private integration modules |

**nix-packages** is a catalog — packages are built per-platform and only the ones listed in the flake overlay are pulled into nix-config:

```nix
overlays = [
  (_final: _prev:
    let np = nix-packages.packages.${system};
        wanted = [ "ndrop" "helium" "t3code" "claude-code" ... ];
    in nixpkgs.lib.filterAttrs (n: _: builtins.elem n wanted) np
  )
];
```

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

# Run targeted format and shell checks
just fmt-check

# Run local pre-commit hooks on staged files
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

The flake also exposes repository checks, so `nix flake check --keep-going`
remains the direct CI-style command. The current formatting check is scoped to
the files owned by the ADR-0043 implementation until the historical repository
formatting baseline is normalized.

## Cluster access

`nix-config` wires Kubernetes access through SOPS-managed kubeconfig secrets,
local kubeconfigs, and Home Manager command wrappers:

- The decrypted kubeconfig lives at `/home/alc/.config/sops-nix/secrets/k3s_kubeconfig` on Linux.
- [modules/home-manager/programs/kubernetes/default.nix](modules/home-manager/programs/kubernetes/default.nix) installs wrappers for `kubectl`, `flux`, `helm`, `k9s`, `kdash`, and selected Kubernetes-aware tools.
- Each wrapper sets a merged `KUBECONFIG` only for that command when it is not already set.
- The merged config starts with a writable current-context file, then the SOPS-managed kubeconfig, then any configured local kubeconfig files that exist.
- Operator machines can import private flake modules such as `bn-bootstrap` to
  append additional kubeconfig files and install engagement-specific tooling.
- Linux and macOS operator profiles also include the optional, separately generated
  `~/.kube/local-bullet-platform-lab-config` and
  `~/.kube/local-funhouse-lab-config` files. Their context names use a
  `local-` prefix to distinguish disposable labs from real clusters; absent
  files are ignored.

This means plain shells, agent subprocesses, and GUI-launched commands do not
need to inherit a global `KUBECONFIG`, and local/script-created contexts can
coexist with the default nux cluster context.

```bash
kubectl config get-contexts
kc minikube
kns kube-system
flux get sources git -A
flux get kustomizations -A
```

To verify a Flux-applied app change end-to-end:

```bash
kubectl -n <namespace> get configmap <name> -o yaml
kubectl -n <namespace> rollout status deploy/<name>
```
