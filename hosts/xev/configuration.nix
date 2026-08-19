# nix-config/hosts/xev/configuration.nix
{
  config,
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
    "${configDir}/modules/nixos/services/netbird/default.nix"
    "${configDir}/modules/nixos/services/wolf-streaming/default.nix"
    "${configDir}/modules/nixos/services/wolf-streaming/worker-runtime.nix"
    "${configDir}/modules/nixos/hardware/nvidia.nix"
    "${configDir}/modules/nixos/virtualisation/k3s/default.nix"
    "${configDir}/modules/nixos/virtualisation/k3s/nvidia-runtime.nix"
    "${configDir}/modules/nixos/virtualisation/longhorn-prereqs/default.nix"
    inputs.nix-secrets.nixosModules.xevK8sBackupReplica
    inputs.nix-secrets.nixosModules.xevPrivate
  ];

  boot.initrd.systemd.enable = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.binfmt.emulatedSystems = ["aarch64-linux"];
  hardware.nvidia.enable = true;
  services.wolf-streaming = {
    enable = true;
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
      helium = {
        enable = true;
        publish = true;
        cooperativeDefault = true;
        pi3Compatibility = true;
        kdeConnect.enable = true;
      };
      brave.enable = true;
      chromium.enable = true;
      firefox.enable = true;
      zen.enable = true;
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

  sops.secrets = {
    k3s_server_token = {
      sopsFile = "${inputs.nix-secrets}/cluster-bootstrap/secrets.yaml";
      key = "k3s_server_token";
      owner = "root";
      group = "root";
    };
  };

  k3s = {
    enable = true;
    nodeIp = "192.168.1.13";
    nodeInterface = "enp6s0";
    # Hardware watchdog reset path has not passed qualification on this host.
    rebootWatchdogSec = "0";
    serverAddr = "https://k8s-api.local:6443";
    tokenFile = config.sops.secrets.k3s_server_token.path;
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

  services.k8s-api-vip = {
    enable = true;
    interface = "enp6s0";
    sourceIp = "192.168.1.13";
    peers = [
      "192.168.1.15"
      "192.168.1.16"
    ];
    priority = 120;
  };

  services.forgejo-actions-runner = {
    enable = true;
    name = "xev";
    capacity = 4;
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
