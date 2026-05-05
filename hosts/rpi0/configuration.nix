# nix-config/hosts/rpi0/configuration.nix
{
  config,
  pkgs,
  inputs,
  username,
  lib,
  configDir,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    "${configDir}/modules/nixos/common/default.nix"
    "${configDir}/modules/nixos/common/server.nix"
    "${configDir}/modules/nixos/virtualisation/k3s/default.nix"
    "${configDir}/modules/nixos/services/netbird/default.nix"
  ];

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  nix.settings.require-sigs = false;
  nix.settings.max-jobs = 0; # always offload builds to xyz

  services.journald.extraConfig = ''
    Storage=persistent
    SystemMaxUse=200M
  '';

  zramSwap.enable = true;

  services.netbird.managed.enable = true;

  # Keep the HA join ports explicit on the host while we bring rpi0 into the
  # embedded-etcd control plane. This avoids relying solely on shared-module
  # firewall state during bootstrap/debug cycles.
  networking.firewall.allowedTCPPorts = [
    2379
    2380
    6443
  ];
  networking.firewall.allowedUDPPorts = [8472];

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
    role = "server";
    serverAddr = "https://192.168.1.15:6443";
    tokenFile = config.sops.secrets.k3s_server_token.path;
    extraFlags = [
      "--node-taint=node-role.kubernetes.io/control-plane=true:NoSchedule"
    ];
  };
}
