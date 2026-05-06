# nix-config/hosts/nex/configuration.nix
{
  config,
  pkgs,
  inputs,
  configDir,
  ...
}: {
  imports = [
    ./hardware-configuration.nix
    "${configDir}/modules/nixos/common/default.nix"
    "${configDir}/modules/nixos/common/server.nix"
    "${configDir}/modules/nixos/virtualisation/k3s/default.nix"
    "${configDir}/modules/nixos/virtualisation/longhorn-prereqs/default.nix"
    "${configDir}/modules/nixos/services/netbird/default.nix"
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
    serverAddr = "https://192.168.1.15:6443";
    tokenFile = config.sops.secrets.k3s_server_token.path;
  };

  services.netbird.managed.enable = true;

  nix.settings.max-jobs = 1; # prefer xyz for builds, but allow local fallback

  networking.hosts."192.168.1.16" = ["nex"];
}
