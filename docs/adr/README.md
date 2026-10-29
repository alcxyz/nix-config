# Architecture Decision Records

Non-obvious decisions in this repo are documented here. Before changing architecture, infrastructure, deployment, library choices, or any area with a clear trade-off — read the relevant ADR first.

Each ADR here states the decision that is true now. When an accepted decision
changes, the ADR is rewritten in place, with an `**Amended:**` date and a
`**History:**` line linking the replaced text in
`archive/<file stem>-history.md`. Superseded and retired ADRs move to
[`archive/`](archive/README.md) with their numbers kept; numbers are never
reused. The root `.ignore` hides the archive from `rg` and `fd`; use `rg -u` or
`git grep` to search it.

| ADR | Title | Status | Area |
|-----|-------|--------|------|
| [ADR-0000](0000-adr-template.md) | Template | Accepted / Proposed (archived ADRs: Superseded / Retired) | — |
| [ADR-0001](0001-nixos-unstable-channel.md) | Use nixos-unstable as the primary nixpkgs channel | Accepted | `flake.nix` |
| [ADR-0002](0002-nix-secrets-separate-repository.md) | Keep private infrastructure material outside nix-config | Accepted | `flake.nix`, private material |
| [ADR-0003](0003-sops-nix-age-ssh-host-key-secrets.md) | Runtime secret deployment with sops-nix | Accepted, redacted | secrets, common |
| [ADR-0004](0004-zfs-autounlock-age-yubikey.md) | Private encrypted pool unlock boundary | Accepted, redacted | encrypted storage, private runbooks |
| [ADR-0005](0005-gpu-passthrough-dynamic-bind.md) | GPU passthrough via dynamic driver bind/unbind | Accepted | xyz, virtualisation |
| [ADR-0006](0006-four-tier-module-layering.md) | Four-tier module layering | Accepted | `modules/`, `hosts/` |
| [ADR-0007](0007-filtered-nix-packages-overlay.md) | Custom packages in a separate repo with filtered overlay | Accepted | `flake.nix`, packages |
| [ADR-0008](0008-pkgsets-centralised-package-management.md) | Centralised package sets via pkgsets.nix | Accepted | `modules/shared/` |
| [ADR-0009](0009-xyz-as-distributed-build-host.md) | Distributed build roles and explicit client opt-in | Accepted, redacted | distributed builds |
| [ADR-0010](0010-amd-igpu-forced-primary-display-nvidia-workaround.md) | Force AMD iGPU as primary display device on dual-GPU workstation | Accepted | xyz, desktop |
| [ADR-0011](0011-unified-keyboard-remapping-kanata.md) | Keyboard remapping with one shared kanata config on Linux and Karabiner on macOS | Accepted | kanata, desktop, mac |
| [ADR-0012](0012-remote-dev-headless-wayland-over-vm.md) | Remote development via headless Wayland session instead of a VM | Accepted | nux, remote-dev |
| [ADR-0013](0013-safe-nix-gc-no-generation-deletion.md) | Safe Nix GC with guarded generation retention | Accepted | all hosts, home-manager, nix.gc |
| [ADR-0014](0014-self-package-zen-browser.md) | Self-package Zen Browser instead of third-party flake | Accepted | `flake.nix`, packages |
| [ADR-0015](0015-dms-plugin-meta-flake.md) | DMS plugin meta-flake | Accepted | `flake.nix`, DMS |
| [ADR-0016](0016-devlog-go-binary-with-weekly-hedgedoc.md) | Devlog as Go binary with weekly summaries | Accepted | devlog, services |
| [ADR-0017](0017-k3s-cluster-topology.md) | k3s cluster topology for home infrastructure | Accepted | infrastructure, hosts |
| [ADR-0018](0018-flux-gitops.md) | Flux as the GitOps operator for k3s | Accepted | k3s, infrastructure |
| [ADR-0019](0019-forge-mirror-pull-systemd-timer.md) | Periodic Forgejo/GitHub drift audit via systemd timer | Accepted | services, forge-mirror |
| [ADR-0020](0020-sops-secrets-in-flux.md) | SOPS decryption for Kubernetes secrets via Flux | Accepted, redacted | Kubernetes, secrets, Flux |
| [ADR-0021](0021-rustfs-s3-object-storage.md) | RustFS as S3-compatible object storage | Accepted | k3s, infrastructure |
| [ADR-0023](0023-k8s-namespace-strategy.md) | Domain-based Kubernetes namespace strategy | Accepted | k3s, gitops |
| [ADR-0024](0024-shared-postgres-cluster.md) | Shared Postgres cluster for k8s services | Proposed | k3s, databases |
| [ADR-0025](0025-tooling-service-discovery-post-k8s.md) | Tooling service discovery after Docker-to-k8s migration | Accepted | tooling, gitops |
| [ADR-0026](0026-unified-source-directory-layout.md) | Unified source directory layout across machines | Accepted, implemented on xyz | all hosts, home-manager |
| [ADR-0029](0029-shared-xdg-llm-config.md) | Shared XDG LLM config for local tooling | Accepted | local tooling, llm config, xdg |
| [ADR-0030](0030-declarative-shared-user-policy-configs.md) | Declarative deployment for shared user policy configs | Accepted | home-manager, shared policy, config deployment |
| [ADR-0031](0031-kubernetes-client-wrappers.md) | Kubernetes client wrappers with per-command kubeconfig | Accepted | k3s, home-manager, client tooling |
| [ADR-0032](0032-ssh-key-ownership-and-deployment.md) | SSH key ownership and deployment | Accepted | ssh, nixos, home-manager, sops |
| [ADR-0033](0033-dms-hyprland-layer-recovery-watcher.md) | DMS Hyprland layer recovery watcher | Accepted | Hyprland, DMS, home-manager |
| [ADR-0034](0034-nex-as-third-k3s-server.md) | Add nex as the third k3s server | Accepted | k3s, hosts, secrets |
| [ADR-0035](0035-host-kernel-policy.md) | Host kernel policy | Accepted | kernels, hosts, k3s |
| [ADR-0036](0036-host-inventory-source-of-truth.md) | Host inventory as source of truth | Accepted | hosts, roles, packages, workspace, k3s |
| [ADR-0037](0037-flake-parts-output-structure.md) | Flake output structure via flake-parts | Accepted | `flake.nix`, `flake/` |
| [ADR-0041](0041-native-forgejo-actions-runners.md) | Native Forgejo Actions runners | Accepted | forgejo, runners, systemd, docker |
| [ADR-0043](0043-selective-external-nix-config-pattern-adoption.md) | Selective external nix-config pattern adoption | Accepted, partially implemented (first-class inventory facts and broader `alc.host` adoption remain) | modules, hosts, checks, workflow |
| [ADR-0044](0044-host-inventory-role-model-for-new-machines.md) | Host inventory role model for new machines | Accepted, partially implemented (richer inventory dimensions remain); amended by ADR-0088 | inventory, hosts, roles |
| [ADR-0045](0045-xev-and-xps-kubernetes-node-onboarding.md) | xev and xps Kubernetes node onboarding | Accepted | xev, xps, k3s, Longhorn, Forgejo |
| [ADR-0046](0046-remotely-managed-family-gaming-laptop.md) | Remotely managed family gaming laptop | Accepted; onboarded, `family-gaming` package set and Netbird-only SSH not yet in place | remote support, Netbird, gaming |
| [ADR-0047](0047-k8s-api-vip.md) | Kubernetes API floating VIP | Accepted | k3s, keepalived, hosts |
| [ADR-0048](0048-xyz-small-nvme-retirement.md) | xyz storage maintenance private runbook boundary | Accepted, redacted | xyz, private runbooks |
| [ADR-0049](0049-xyz-sensitive-host-bootstrap-boundary.md) | xyz sensitive host bootstrap boundary | Accepted | xyz, private runbooks |
| [ADR-0050](0050-xyz-appstate-and-local-backup-boundary.md) | xyz appstate and local backup boundary | Accepted | xyz, ZFS, backups |
| [ADR-0051](0051-xev-replaces-rpi0-k3s-server.md) | xev replaces rpi0 as a k3s server | Accepted | k3s, xev, rpi0, etcd |
| [ADR-0052](0052-xev-primary-k8s-backup-target.md) | xev primary Kubernetes backup target with xyz ZFS replica | Accepted | xev, xyz, k3s backups |
| [ADR-0053](0053-controller-first-xps-couch-session.md) | Controller-first XPS couch session | Accepted | xps, couch, Moonlight, SteamHeadless |
| [ADR-0054](0054-mac-hosted-synergy1-with-waynergy-clients.md) | Mac-hosted Synergy 1 with Waynergy clients | Accepted | mac, xps, xyz, Synergy, Waynergy |
| [ADR-0055](0055-nixbox-session-and-system-splash-boundary.md) | Stage the NIXBOX splash across boot and graphical session | Accepted | xps, couch, Plymouth, Quickshell |
| [ADR-0056](0056-containerized-remote-browser-streaming.md) | Containerized remote browser streaming | Accepted, implemented | xev, xps, Wolf, Moonlight, browsers |
| [ADR-0058](0058-xyz-dedicated-runtime-storage.md) | Dedicated xyz runtime storage | Accepted | xyz, Docker, k3s, Steam-headless, ZFS |
| [ADR-0059](0059-file-selective-home-backup-and-storage-monitoring.md) | File-selective home backup and host storage monitoring | Accepted | xyz, home backup, storage monitoring |
| [ADR-0060](0060-gateway-owned-unifi-and-independent-dns.md) | Gateway-owned UniFi and independent DNS pair | Accepted | unifi, dns, network services |
| [ADR-0061](0061-retire-xyz-k3s-agent.md) | Retire the xyz k3s agent | Accepted | xyz, xev, k3s, Wolf, browsers, Longhorn |
| [ADR-0062](0062-xev-tank-storage-and-media-service-migration.md) | Move bulk storage ownership and media services to xev | Accepted, amended by ADR-0064; staged (destination preparation in progress, no stage complete) | xev, xyz, storage, media services |
| [ADR-0063](0063-split-replaceable-bulk-and-secure-storage.md) | Split replaceable bulk data from secure storage | Accepted, implemented | xyz, bulk storage, ZFS, media services |
| [ADR-0064](0064-keep-secure-storage-on-xyz.md) | Keep secure storage on xyz while moving bulk storage to xev | Accepted, staged | xyz, xev, secure storage, bulk storage, media services |
| [ADR-0065](0065-narrow-xyz-game-session-compatibility-repairs.md) | Keep xyz game-session compatibility repairs narrow and event-scoped | Accepted | xyz, Hyprland, XWayland, DMS, Heroic |
| [ADR-0066](0066-direct-umu-launchers-with-heroic-qa-fallback.md) | Use direct UMU launchers with a Heroic QA fallback | Accepted | xyz, UMU, Proton, Battle.net, Heroic |
| [ADR-0067](0067-explicit-consumer-and-platform-validation.md) | Explicit consumer and platform validation | Accepted | flake checks, Forgejo, package promotion |
| [ADR-0068](0068-k8s-node-power-lifecycle.md) | Kubernetes node power lifecycle (formerly the duplicate ADR-0036) | Accepted | k3s, node lifecycle, maintenance helpers |
| [ADR-0069](0069-maintained-project-dev-qa.md) | Maintained project development QA inputs | Accepted | flake inputs, DMS, release workflow |
| [ADR-0070](0070-action-bound-credential-consent.md) | Action-bound credential consent | Accepted | Polkit, DMS, credential brokers |
| [ADR-0071](0071-shared-container-network-namespace-mount.md) | Establish the shared container network namespace mount before runtimes | Accepted | containers, k3s, systemd |
| [ADR-0072](0072-isolated-runner-docker.md) | Isolate runner Docker execution in a bounded rootless service | Accepted | Forgejo runners, Docker, systemd |
| [ADR-0073](0073-native-macos-gui-apps-with-nix-managed-settings.md) | Native macOS GUI apps with Nix-managed settings | Accepted | macOS, Homebrew, Home Manager, GUI apps |
| [ADR-0074](0074-phased-podman-coexistence.md) | Qualify Podman through staged Docker coexistence | Accepted; Docker stays beside Podman, no Docker engine qualified for retirement | containers, development, CI |
| [ADR-0076](0076-dms-lock-exact-head-publication.md) | Validate and merge DMS lock updates at an exact head | Accepted | DMS lock, Forgejo Actions |
| [ADR-0077](0077-ai-stack-profile-outside-home-manager.md) | Update the AI stack in its own profile, outside Home Manager | Accepted | T3 Code, AI providers, Home Manager |
| [ADR-0080](0080-promoted-package-ref.md) | Promote validated package revisions as a ref, lock them on demand | Accepted | package promotion, T3 Code, deploy |
| [ADR-0082](0082-fence-release-on-peer-evidence.md) | Release a self-fence only on positive peer evidence | Accepted | k3s, self-fence, kreboot |
| [ADR-0083](0083-podman-cleanup-completion-fence.md) | Fence admission until Podman cleanup completion is known | Accepted, qualification required | Forgejo runners, Podman cleanup |
| [ADR-0086](0086-released-tool-inputs.md) | Refresh released platform tools with tools-update | Accepted | flake inputs, release workflow |
| [ADR-0087](0087-side-by-side-dev-tools.md) | Install dev builds of released tools side by side | Accepted | flake inputs, release workflow |
| [ADR-0088](0088-tv-clients-share-one-appliance-profile.md) | TV clients share one appliance profile | Accepted | rpi0, rpi1, TV clients, Moonlight, Bluetooth audio |
| [ADR-0089](0089-released-and-dev-app-inputs.md) | Released and dev app inputs | Accepted | flake inputs, release workflow |
| [ADR-0090](0090-install-bivrost-directly.md) | Install Bivrost directly, configured by the work flake | Accepted | Bivrost, the work flake, operator homes |
| [ADR-0092](0092-t3-preview-browser-from-nix.md) | Provide T3's preview browser from the Nix package | Accepted | T3 Code, previews, nix-packages |
| [ADR-0094](0094-browser-roles.md) | One Chromium browser (Brave Origin), Zen provisional | Accepted, Zen provisional | browsers, xyz, xps, mac, Wolf |
| [ADR-0095](0095-bounded-workspace-sync-go-pilot.md) | Evaluate Go through one bounded workspace-sync pilot | Accepted; source integration implemented, runtime qualification pending | workspace reconciliation, nix-packages, Home Manager |
| [ADR-0096](0096-bounded-first-timer-freshness.md) | Bound the first-timer freshness exception after reboot | Accepted | storage health, timers |
| [ADR-0097](0097-ci-fast-runner-label.md) | Route opted-in CI jobs to fast hosts with a `ci-fast` label | Accepted; xyz serves `ci-fast`, xev while xyz's fast runner is down | Forgejo runners, xyz, xev, workflows |
| [ADR-0098](0098-date-tagged-promotions.md) | Tag each promotion to `main` with a date version | Accepted | promotions, tags, Forgejo releases |
| [ADR-0100](0100-instance-wide-podman-runners.md) | Register the Podman runners instance-wide | Accepted | Forgejo runners, xyz, xev, nex, nux |
| [ADR-0102](0102-loopback-remote-view-of-xyz.md) | View and drive xyz's live desktop through a loopback wayvnc | Accepted | xyz, mac, remote access, Home Manager |

The [original Kubernetes node lifecycle URL](0036-k8s-node-power-lifecycle.md)
is retained as a compatibility pointer to ADR-0068. ADR-0036 identifies the
host inventory decision.
