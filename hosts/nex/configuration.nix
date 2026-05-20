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
    "${configDir}/modules/nixos/services/forgejo-actions-runner/default.nix"
    "${configDir}/modules/nixos/services/k8s-api-vip/default.nix"
    "${configDir}/modules/nixos/virtualisation/k3s/default.nix"
    "${configDir}/modules/nixos/virtualisation/longhorn-prereqs/default.nix"
    "${configDir}/modules/nixos/services/netbird/default.nix"
  ];

  boot.initrd.systemd.enable = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  alc.distributedBuildClient.enable = true;

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
    tlsSans = [
      "k8s-api.local"
      "192.168.1.250"
    ];
  };

  fileSystems."/var/lib/longhorn" = {
    device = "/dev/disk/by-label/nex-longhorn";
    fsType = "ext4";
  };

  systemd.services.k3s = {
    requires = ["var-lib-longhorn.mount"];
    after = ["var-lib-longhorn.mount"];
  };

  services.k8s-api-vip = {
    enable = true;
    interface = "eno1";
    sourceIp = "192.168.1.16";
    peers = [
      "192.168.1.15"
      "192.168.1.3"
    ];
    priority = 100;
  };

  services.netbird.managed.enable = true;

  services.forgejo-actions-runner = {
    enable = true;
    name = "nex";
    capacity = 2;
    labels = [
      "ubuntu-latest:docker://node:20-bookworm"
      "nex:docker://node:20-bookworm"
      "docker:docker://node:20-bookworm"
    ];
  };

  nix.settings.max-jobs = 1; # prefer xyz for builds, but allow local fallback

  networking.hosts = {
    "192.168.1.16" = ["nex"];
    "192.168.1.250" = ["k8s-api.local"];
  };
}
