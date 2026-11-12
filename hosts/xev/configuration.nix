# nix-config/hosts/xev/configuration.nix
{
  inputs,
  lib,
  pkgs,
  configDir,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    "${configDir}/modules/nixos/common/default.nix"
    "${configDir}/modules/nixos/common/server.nix"
    "${configDir}/modules/nixos/services/forgejo-actions-runner/default.nix"
    "${configDir}/modules/nixos/services/k8s-backup-s3/default.nix"
    "${configDir}/modules/nixos/services/k8s-api-vip/default.nix"
    inputs.nix-secrets.nixosModules.k8sApiVipPolicy
    inputs.nix-secrets.nixosModules.k3sClusterSecrets
    inputs.nix-secrets.nixosModules.openbaoClusterPolicy
    "${configDir}/modules/nixos/services/rustfs-native/default.nix"
    inputs.nix-secrets.nixosModules.rustfsApplicationPolicy
    "${configDir}/modules/nixos/services/netbird/default.nix"
    "${configDir}/modules/nixos/services/wolf-streaming/default.nix"
    "${configDir}/modules/nixos/services/wolf-streaming/worker-runtime.nix"
    "${configDir}/modules/nixos/hardware/nvidia.nix"
    "${configDir}/modules/nixos/hardware/zfs-latest-kernel.nix"
    "${configDir}/modules/nixos/virtualisation/k3s/default.nix"
    "${configDir}/modules/nixos/virtualisation/k3s/nvidia-runtime.nix"
    "${configDir}/modules/nixos/virtualisation/longhorn-prereqs/default.nix"
    inputs.nix-secrets.nixosModules.zfsAutoUnlock
    inputs.nix-secrets.nixosModules.xevK8sBackupReplica
    inputs.nix-secrets.nixosModules.xevPrinter
    inputs.nix-secrets.nixosModules.xevPrivate
  ];

  alc.private.openbaoClusterPolicy.enable = true;
  alc.private.rustfsApplication.enable = true;
  alc.private.rustfsApplication.vipEnable = true;

  boot.binfmt.emulatedSystems = ["aarch64-linux"];
  hardware.nvidia.enable = true;

  # xev freezes hard without a kernel message (gitops#1318). The SP5100 TCO
  # watchdog resets a frozen host instead of waiting for the operator, and a
  # detected lockup panics so its log reaches pstore before the reboot. The
  # kubelet also sets kernel.panic to 10; set it from boot so a panic reboots
  # while k3s is down or fenced.
  systemd.settings.Manager.RuntimeWatchdogSec = "1min";
  boot.kernel.sysctl = {
    "kernel.panic" = 10;
    "kernel.softlockup_panic" = 1;
    "kernel.hardlockup_panic" = 1;
  };

  # ADR-0062/0064 preparation only; bulk mounts and consumers are activated
  # together with the separately reviewed physical ownership cutover.
  boot.supportedFilesystems = ["xfs"];
  environment.systemPackages = with pkgs; [
    acl
    attr
    mergerfs
    mergerfs-tools
    psmisc
    xfsprogs
  ];

  # Randomly assigned ZFS host ID; it is stable and is not derived from a
  # hardware identifier. Merely enabling ZFS support does not import a pool.
  networking.hostId = "abe0d0f3";
  services.wolf-streaming = {
    enable = true;
    image = "git.alc.xyz/alcxyz/wolf:dev-20260911t113536z-71617994ca93@sha256:88e3004e58b17c27f152914eec0d48a0650bb60c63c238846ebd01e27d47e43f";
    publicCoordinator = "external";
    publicRuntimeDirectory = "/run/nixbox-public-browser-worker/runtime";
    sessionIdleTimeoutSeconds = 30 * 60;
    pipelineWatchdog.enable = true;
    vramWatchdog.enable = true;
    prunedApplicationTitles = [
      "Remote Firefox"
      "Test ball"
    ];
    browserImages = {
      enable = true;
      # Brave Origin replaced Helium as the shared public browser (#628).
      public = {
        enable = true;
        image = "git.alc.xyz/alcxyz/wolf-brave-origin:dev-20261012t000409z-2f433d8c2536@sha256:b00bc3f1235b4e0e8e67f5f9bedfc2296899260d845aafc991a804cb0a86e842";
        icon = "https://brave.com/static-assets/images/brave-logo-sans-text.svg";
        cooperative = true;
        pi3Compatibility = true;
        kdeConnect.enable = true;
      };
      # The Brave app slot runs Brave Origin, as in the Kubernetes private
      # browser; reusing the public image keeps one pinned pull.
      brave = {
        enable = true;
        image = "git.alc.xyz/alcxyz/wolf-brave-origin:dev-20261012t000409z-2f433d8c2536@sha256:b00bc3f1235b4e0e8e67f5f9bedfc2296899260d845aafc991a804cb0a86e842";
      };
      zen = {
        enable = true;
        image = "git.alc.xyz/alcxyz/wolf-zen:dev-20260911t114225z-71617994ca93@sha256:f6ec8f973452de031883fdf1c69f7e50c255aea2ddb092f6a2ba6252d83ace10";
      };
    };
  };

  services.netbird.managed = {
    enable = true;
    disableDns = true;
  };

  # ---- Nix Settings ----
  # Allow this host to build for remote machines via SSH.
  nix.settings.allowed-uris = [
    "ssh-ng://*"
    "ssh://*"
    "file://*"
    "https://*"
  ];

  k3s = {
    enable = true;
    nodeIp = "192.168.1.13";
    nodeInterface = "enp10s0";
    serverAddr = "https://k8s-api.local:6443";
    extraFlags = [
      "--node-label=nixbox.alc.xyz/protected-browser-worker=true"
    ];
    tlsSans = [
      "k8s-api.local"
      "192.168.1.250"
    ];
  };

  fileSystems."/var/lib/longhorn" = {
    device = "/dev/disk/by-label/xev-longhorn";
    fsType = "ext4";
    options = [
      "nofail"
      "x-systemd.device-timeout=30s"
      "x-systemd.mount-timeout=30s"
    ];
  };

  fileSystems."/var/lib/k8s-backup-replica" = {
    device = "/dev/disk/by-label/xev-k8s-backup";
    fsType = "ext4";
    options = [
      "nofail"
      "x-systemd.device-timeout=15s"
      "x-systemd.mount-timeout=30s"
    ];
  };

  fileSystems."/var/lib/longhorn-ssd2" = {
    # ext4 labels are limited to 16 bytes; keep this stable label below that
    # limit so mkfs and e2label cannot silently truncate the mount identity.
    device = "/dev/disk/by-label/xev-lh-ssd2";
    fsType = "ext4";
    options = [
      "nofail"
      "x-systemd.device-timeout=15s"
      "x-systemd.mount-timeout=30s"
    ];
  };

  alc.longhornPrereqs.storageMountUnit = "var-lib-longhorn.mount";
  alc.longhornPrereqs.additionalStorageTargets = [
    {
      path = "/var/lib/longhorn-ssd2";
      mountUnit = "var-lib-longhorn\\x2dssd2.mount";
    }
  ];

  networking.hosts = {
    "192.168.1.13" = ["xev"];
    "192.168.1.250" = ["k8s-api.local"];
  };

  services.forgejo-actions-runner = {
    enable = true;
    package = pkgs.callPackage "${inputs.nix-packages}/pkgs/forgejo-runner-cancellation" {};
    # Hold the runners while the disk is low, and report a runner left off
    # (ADR-0106).
    runnerHold = {
      diskSpace.enable = true;
      alert.enable = true;
    };
    # Reset the Podman store offline while the runners are idle (ADR-0105).
    # Leftovers reset the 4G scratch at 25% (1G) or the volume filesystem at
    # 25% (about 0.9G; its inode tables take 6.25% of the 4G device), so a
    # pool job still has 3G of scratch and about 2.8G of volumes (ADR-0108).
    podmanStoreReset = {
      enable = true;
      scratchTriggerPercent = 25;
    };
    # Engines pull docker.io images through the LAN cache, falling back to
    # docker.io when it is down (#917).
    registryMirror = "registry-cache.alc.xyz";
    registryMirrorCaFile = ../../modules/nixos/services/forgejo-actions-runner/registry-cache-ca.crt;
    isolatedDocker.enable = true;
    isolatedDocker.retention.enable = true;
    podmanCanary = {
      enable = true;
      package = pkgs.callPackage "${inputs.nix-packages}/pkgs/forgejo-runner-cancellation" {};
      # The pool runner also serves ci-fast beside xyz's (ADR-0097), so fast
      # jobs still run while xyz holds its runners for a game.
      labels = [
        "forgejo-podman:docker://docker.io/library/docker:27-cli"
        "ci-fast:docker://docker.io/library/docker:27-cli"
      ];
      # One pool slot, as every pool runner (ADR-0106), so the scratch is one
      # job's limit. Job throwaway data in RAM, images on disk (ADR-0108,
      # #1027); the tmpfs counts against the CI memory limits below.
      # The 8G a pool job had in the tmpfs is split in two: 4G of tmpfs for
      # its container layers, and 4G of zram for its volumes, where BuildKit
      # builds that run dpkg work (ADR-0108).
      scratch = {
        enable = true;
        size = "4G";
        volumes = {
          enable = true;
          size = "4G";
        };
      };
      # A shared, read-only Nix store for Podman Nix jobs (ADR-0109, #1038).
      nixCache = {
        enable = true;
        # On the NVMe root, not the CI SSD, so it adds no wear
        # there (owner, 9 Nov); a full 30G store leaves about 44G free, just
        # above the filler's 20% floor, where it stops adding.
        dataPath = "/var/lib/forgejo-ci-nix-cache";
        # Small staging for flake inputs: the filler runs in the CI slice,
        # whose budget here holds the 4G scratch and the job; it adds paths
        # only between jobs, but a job can start while it stages an input.
        stageSize = "1G";
        offers = {
          forge = "https://git.alc.xyz";
          repos = ["alcxyz/nix-packages"];
        };
      };
    };
    resourcePolicy.enable = true;
    # The cluster comes first: CI stays at half the memory, with the throttle
    # a few points below, and its 4G of zram for volumes, which no cgroup is
    # charged for, comes off both limits (about 12.8%). The throttle holds
    # the 4G scratch beside the pool job and the rarely used Docker slot's
    # job, about 6G for both (ADR-0108).
    resourcePolicy.memoryHigh = "32%";
    resourcePolicy.memoryMax = "37%";
    # Both runners share that aggregate budget. One Docker slot serves the few
    # jobs that still select a Docker label.
    capacity = 1;
    labels = [
      "forgejo-docker:docker://node:20-bookworm"
    ];
  };

  # xev was first installed from a NixOS 25.11 installer generation.
  system.stateVersion = lib.mkForce "25.11";

  nix.settings.max-jobs = 12;
}
