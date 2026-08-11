# Architecture Decision Records

Non-obvious decisions in this repo are documented here. Before changing architecture, infrastructure, deployment, library choices, or any area with a clear trade-off — read the relevant ADR first.

| ADR | Title | Status | Area |
|-----|-------|--------|------|
| [ADR-0000](0000-adr-template.md) | Template | Accepted / Superseded / Deprecated | — |
| [ADR-0001](0001-nixos-unstable-channel.md) | Use nixos-unstable as the primary nixpkgs channel | Accepted | `flake.nix` |
| [ADR-0002](0002-nix-secrets-separate-repository.md) | Keep private infrastructure material outside nix-config | Accepted, amended | `flake.nix`, private material |
| [ADR-0003](0003-sops-nix-age-ssh-host-key-secrets.md) | Use sops-nix with age decryption via SSH host key | Accepted | secrets, common |
| [ADR-0004](0004-zfs-autounlock-age-yubikey.md) | Private encrypted pool unlock boundary | Accepted, redacted | encrypted storage, private runbooks |
| [ADR-0005](0005-gpu-passthrough-dynamic-bind.md) | GPU passthrough via dynamic driver bind/unbind | Accepted | xyz, virtualisation |
| [ADR-0006](0006-four-tier-module-layering.md) | Four-tier module layering | Accepted | `modules/`, `hosts/` |
| [ADR-0007](0007-filtered-nix-packages-overlay.md) | Custom packages in a separate repo with filtered overlay | Accepted | `flake.nix`, packages |
| [ADR-0008](0008-pkgsets-centralised-package-management.md) | Centralised package sets via pkgsets.nix | Accepted, amended | `modules/shared/` |
| [ADR-0009](0009-xyz-as-distributed-build-host.md) | xyz and mac distributed build posture | Accepted, amended | distributed builds |
| [ADR-0010](0010-amd-igpu-forced-primary-display-nvidia-workaround.md) | Force AMD iGPU as primary display device on dual-GPU workstation | Accepted | xyz, desktop |
| [ADR-0011](0011-unified-keyboard-remapping-kanata.md) | Unified keyboard remapping via kanata across all hosts and keyboards | Accepted, amended | kanata, desktop, mac |
| [ADR-0012](0012-remote-dev-headless-wayland-over-vm.md) | Remote development via headless Wayland session instead of a VM | Accepted | nux, remote-dev |
| [ADR-0013](0013-safe-nix-gc-no-generation-deletion.md) | Safe nix GC — never auto-delete profile generations | Accepted | mac, nix.gc |
| [ADR-0014](0014-self-package-zen-browser.md) | Self-package Zen Browser instead of third-party flake | Accepted | `flake.nix`, packages |
| [ADR-0015](0015-dms-plugin-meta-flake.md) | DMS plugin meta-flake | Accepted | `flake.nix`, DMS |
| [ADR-0016](0016-devlog-go-binary-with-weekly-hedgedoc.md) | Devlog as Go binary with weekly summaries and HedgeDoc posting | Accepted | devlog, services |
| [ADR-0017](0017-k3s-cluster-topology.md) | k3s cluster topology for home infrastructure | Accepted | infrastructure, hosts |
| [ADR-0018](0018-flux-gitops.md) | Flux as the GitOps operator for k3s | Accepted | k3s, infrastructure |
| [ADR-0019](0019-forge-mirror-pull-systemd-timer.md) | Periodic Forgejo/GitHub drift audit via systemd timer | Accepted | services, forge-mirror |
| [ADR-0020](0020-sops-secrets-in-flux.md) | SOPS decryption for k8s secrets via Flux (dedicated age keypair) | Accepted | k3s, secrets, Flux |
| [ADR-0021](0021-rustfs-s3-object-storage.md) | RustFS as S3-compatible object storage | Accepted | k3s, infrastructure |
| [ADR-0022](0022-universal-agent-instructions.md) | Universal agent instructions via AGENTS.md | Accepted | nix-secrets, home-manager |
| [ADR-0023](0023-k8s-namespace-strategy.md) | Domain-based Kubernetes namespace strategy | Accepted | k3s, gitops |
| [ADR-0024](0024-shared-postgres-cluster.md) | Shared Postgres cluster for k8s services | Proposed | k3s, databases |
| [ADR-0025](0025-tooling-service-discovery-post-k8s.md) | Tooling service discovery after Docker-to-k8s migration | Accepted | tooling, gitops |
| [ADR-0026](0026-unified-source-directory-layout.md) | Unified source directory layout across machines | Accepted, implemented on xyz | all hosts, home-manager |
| [ADR-0027](0027-wcap-pipewire-virtual-sink-audio-isolation.md) | Retired PipeWire virtual sink for per-app audio isolation (wcap) | Retired | `modules/nixos/common/`, hyprland |
| [ADR-0028](0028-agent-instruction-sync-check.md) | Agent instruction sync via packaged check-agent-sync tool | Accepted | agent instructions, nix-packages, nix-secrets |
| [ADR-0029](0029-shared-xdg-llm-config.md) | Shared XDG LLM config for local tooling | Accepted | local tooling, llm config, xdg |
| [ADR-0030](0030-declarative-shared-user-policy-configs.md) | Declarative deployment for shared user policy configs | Accepted | home-manager, shared policy, config deployment |
| [ADR-0031](0031-kubernetes-client-wrappers.md) | Kubernetes client wrappers with per-command kubeconfig | Accepted | k3s, home-manager, client tooling |
| [ADR-0032](0032-ssh-key-ownership-and-deployment.md) | SSH key ownership and deployment | Accepted | ssh, nixos, home-manager, sops |
| [ADR-0033](0033-dms-hyprland-layer-recovery-watcher.md) | DMS Hyprland layer recovery watcher | Accepted | Hyprland, DMS, home-manager |
| [ADR-0034](0034-nex-as-third-k3s-server.md) | Add nex as the third k3s server | Accepted | k3s, hosts, secrets |
| [ADR-0035](0035-host-kernel-policy.md) | Host kernel policy | Accepted | kernels, hosts, k3s |
| [ADR-0036](0036-host-inventory-source-of-truth.md) | Host inventory as source of truth | Accepted | hosts, roles, packages, workspace, k3s |
| [ADR-0037](0037-flake-parts-output-structure.md) | Flake output structure via flake-parts | Accepted | `flake.nix`, `flake/` |
| [ADR-0038](0038-unifi-native-active-passive.md) | UniFi native NixOS active/passive runtime | Accepted | unifi, nux, rpi0 |
| [ADR-0039](0039-xyz-zfs-s3-backup-target.md) | xyz ZFS-backed S3 target for cluster backups | Superseded by ADR-0052 | xyz, ZFS, k3s backups |
| [ADR-0040](0040-unifi-automatic-ha-target.md) | UniFi automatic HA target | Proposed | unifi, nux, rpi0, failover |
| [ADR-0041](0041-native-forgejo-actions-runners.md) | Native Forgejo Actions runners | Implemented | forgejo, runners, systemd, docker |
| [ADR-0042](0042-shared-media-group-permissions.md) | Shared media group permissions for torrent and Stash storage | Accepted | media, torrent, stash, xyz |
| [ADR-0043](0043-selective-external-nix-config-pattern-adoption.md) | Selective external nix-config pattern adoption | Accepted, partially implemented | modules, hosts, checks, workflow |
| [ADR-0044](0044-host-inventory-role-model-for-new-machines.md) | Host inventory role model for new machines | Accepted, partially implemented | inventory, hosts, roles |
| [ADR-0045](0045-xev-and-xps-kubernetes-node-onboarding.md) | xev and xps Kubernetes node onboarding | Accepted, xev promoted to k3s server; xps workstation-only | xev, xps, k3s, Longhorn, Forgejo |
| [ADR-0046](0046-remotely-managed-family-gaming-laptop.md) | Remotely managed family gaming laptop | Accepted, prepared | remote support, Netbird, gaming |
| [ADR-0047](0047-k8s-api-vip.md) | Kubernetes API floating VIP | Accepted | k3s, keepalived, hosts |
| [ADR-0048](0048-xyz-small-nvme-retirement.md) | xyz storage maintenance private runbook boundary | Accepted, redacted | xyz, private runbooks |
| [ADR-0049](0049-xyz-sensitive-host-bootstrap-boundary.md) | xyz sensitive host bootstrap boundary | Accepted | xyz, private runbooks |
| [ADR-0050](0050-xyz-appstate-and-local-backup-boundary.md) | xyz appstate and local backup boundary | Accepted, amended | xyz, ZFS, backups |
| [ADR-0051](0051-xev-replaces-rpi0-k3s-server.md) | xev replaces rpi0 as a k3s server | Accepted | k3s, xev, rpi0, etcd |
| [ADR-0052](0052-xev-primary-k8s-backup-target.md) | xev primary Kubernetes backup target with xyz ZFS replica | Accepted, staged | xev, xyz, k3s backups |
| [ADR-0053](0053-controller-first-xps-couch-session.md) | Controller-first XPS couch session | Accepted | xps, couch, Moonlight, SteamHeadless |
| [ADR-0054](0054-mac-hosted-synergy1-with-waynergy-clients.md) | Mac-hosted Synergy 1 with Waynergy clients | Accepted | mac, xps, xyz, Synergy, Waynergy |
| [ADR-0055](0055-nixbox-session-and-system-splash-boundary.md) | Stage the NIXBOX splash across boot and graphical session | Accepted | xps, couch, Plymouth, Quickshell |
| [ADR-0056](0056-containerized-remote-browser-streaming.md) | Containerized remote browser streaming | Accepted, implemented | xev, xps, Wolf, Moonlight, browsers |
| [ADR-0057](0057-kubernetes-managed-protected-browser-mobility.md) | Kubernetes-managed Wolf browser mobility | Accepted, active | xyz, xev, Wolf, Kubernetes, Longhorn |
| [ADR-0058](0058-xyz-dedicated-runtime-storage.md) | Dedicated xyz runtime storage | Accepted, amended | xyz, Docker, k3s, Steam-headless, ZFS |
| [ADR-0059](0059-file-selective-home-backup-and-storage-monitoring.md) | File-selective home backup and host storage monitoring | Accepted | xyz, home backup, storage monitoring |
