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
    "${configDir}/modules/nixos/services/k8s-api-vip/default.nix"
    "${configDir}/modules/nixos/virtualisation/k3s/default.nix"
    "${configDir}/modules/nixos/virtualisation/longhorn-prereqs/default.nix"
  ];

  boot.initrd.systemd.enable = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.binfmt.emulatedSystems = ["aarch64-linux"];

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
    serverAddr = "https://k8s-api.local:6443";
    tokenFile = config.sops.secrets.k3s_server_token.path;
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

  alc.longhornPrereqs.storageMountUnit = "var-lib-longhorn.mount";

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
