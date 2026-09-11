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
    "${configDir}/modules/nixos/hardware/openzfs-7-1.nix"
    "${configDir}/modules/nixos/virtualisation/k3s/default.nix"
    "${configDir}/modules/nixos/virtualisation/k3s/nvidia-runtime.nix"
    "${configDir}/modules/nixos/virtualisation/longhorn-prereqs/default.nix"
    inputs.nix-secrets.nixosModules.zfsAutoUnlock
    inputs.nix-secrets.nixosModules.xevK8sBackupReplica
    inputs.nix-secrets.nixosModules.xevPrinter
    inputs.nix-secrets.nixosModules.xevPrivate
  ];

  boot.initrd.systemd.enable = true;
  boot.binfmt.emulatedSystems = ["aarch64-linux"];
  hardware.nvidia.enable = true;

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
      helium = {
        enable = true;
        image = "git.alc.xyz/alcxyz/wolf-helium:dev-20260911t113411z-71617994ca93@sha256:c7fac96c3a43a79cbce720585f95227a14457da65ffa26666153ca0e3bff5f89";
        publish = true;
        cooperativeDefault = true;
        pi3Compatibility = true;
        kdeConnect.enable = true;
      };
      brave = {
        enable = true;
        image = "git.alc.xyz/alcxyz/wolf-brave:dev-20260911t113232z-71617994ca93@sha256:3f061998f9ad7081c6ad4fa474706b6469559dee9c410d2309763d7a1a454aa1";
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
    nodeInterface = "enp10s0";
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
    interface = "enp10s0";
    sourceIp = "192.168.1.13";
    peers = [
      "192.168.1.15"
      "192.168.1.16"
    ];
    priority = 120;
  };

  services.forgejo-actions-runner = {
    enable = true;
    ioPressureGuard.enable = true;
    name = "xev";
    # Keep CI admission serial on a host that also serves the Kubernetes
    # control plane and storage. Other eligible runners can consume queued
    # work without allowing one poller to admit a local build burst.
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
