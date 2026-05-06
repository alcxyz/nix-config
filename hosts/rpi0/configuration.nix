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
    "${configDir}/modules/nixos/services/pihole-native/default.nix"
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
    53
    2379
    2380
    6443
    8081
  ];
  networking.firewall.allowedUDPPorts = [
    53
    8472
  ];

  sops.secrets = {
    k3s_server_token = {
      sopsFile = "${inputs.nix-secrets}/cluster-bootstrap/secrets.yaml";
      key = "k3s_server_token";
      owner = "root";
      group = "root";
    };
    pihole_secret_key = {
      sopsFile = "${inputs.nix-secrets}/apps/secrets.yaml";
      owner = "pihole";
      group = "pihole";
    };
  };

  services.unbound = {
    enable = true;
    resolveLocalQueries = false;
    settings.server = {
      interface = ["127.0.0.1"];
      port = 5335;
      access-control = ["127.0.0.0/8 allow"];
      do-ip4 = true;
      do-ip6 = false;
      do-udp = true;
      do-tcp = true;
      prefer-ip6 = false;
      edns-buffer-size = 1232;
      harden-glue = true;
      harden-dnssec-stripped = true;
      prefetch = true;
      qname-minimisation = true;
      rrset-roundrobin = true;
    };
  };

  services.alc-pihole-native = {
    enable = true;
    listenInterface = "end0";
    hostName = "pihole.rpi0.local";
    webPort = 8081;
    upstream = "127.0.0.1#5335";
    stateDirectory = "/var/lib/pihole/etc";
    passwordFile = config.sops.secrets.pihole_secret_key.path;
  };

  k3s = {
    enable = true;
    serverAddr = "https://192.168.1.15:6443";
    tokenFile = config.sops.secrets.k3s_server_token.path;
  };
}
