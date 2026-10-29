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
    # Alert when CI admission stays held beyond its bound (ADR-0072, #894).
    holdMonitor.enable = true;
    package = pkgs.callPackage "${inputs.nix-packages}/pkgs/forgejo-runner-cancellation" {};
    ioPressureGuard.enable = true;
    ioPressureGuard.admissionControl.enable = true;
    ioPressureGuard.diskSpace.enable = true;
    idlePodmanCleanup.enable = true;
    idlePodmanCleanup.pressureOnly = false;
    isolatedDocker.enable = true;
    isolatedDocker.retention.enable = true;
    podmanCanary = {
      enable = true;
      package = pkgs.callPackage "${inputs.nix-packages}/pkgs/forgejo-runner-cancellation" {};
      # Preserve the manual canary workflow while jobs adopt the shared label.
      labels = [
        "forgejo-podman:docker://docker.io/library/docker:27-cli"
        "forgejo-podman-canary:docker://docker.io/library/docker:27-cli"
      ];
      # Most jobs use the Podman pool, so it takes the slot the Docker runner
      # gave up.
      capacity = 3;
      # Serves ci-fast only while xyz-fast is down (ADR-0097), as xyz
      # reports over NetBird (100.82.168.59 is xyz's NetBird address).
      extraRunners.fast = {
        labels = ["ci-fast:docker://docker.io/library/docker:27-cli"];
        capacity = 1;
        standby = {
          enable = true;
          statusUrl = "http://100.82.168.59:9478/";
          statusInterface = "wt0";
        };
      };
    };
    resourcePolicy.enable = true;
    name = "xev";
    # Independent jobs share the existing aggregate resource budget; the
    # host-wide CPU, memory, and I/O limits remain unchanged. One Docker slot
    # serves the few jobs that still select a Docker label.
    capacity = 1;
    labels = [
      "forgejo-docker-primary:docker://node:20-bookworm"
      "ubuntu-latest:docker://node:20-bookworm"
      "docker:docker://node:20-bookworm"
      "xev:docker://node:20-bookworm"
    ];
  };

  # xev was first installed from a NixOS 25.11 installer generation.
  system.stateVersion = lib.mkForce "25.11";

  nix.settings.max-jobs = 12;
}
