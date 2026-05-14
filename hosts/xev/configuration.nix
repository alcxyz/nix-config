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
    "${configDir}/modules/nixos/virtualisation/k3s/default.nix"
    "${configDir}/modules/nixos/virtualisation/longhorn-prereqs/default.nix"
  ];

  boot.initrd.systemd.enable = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

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
    serverAddr = "https://k8s-api.local:6443";
    tokenFile = config.sops.secrets.k3s_server_token.path;
  };

  networking.hosts = {
    "192.168.1.13" = ["xev"];
    "192.168.1.250" = ["k8s-api.local"];
  };

  # xev was first installed from a NixOS 25.11 installer generation.
  system.stateVersion = lib.mkForce "25.11";

  nix.settings.max-jobs = 2;
}
