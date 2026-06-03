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
    "${configDir}/modules/nixos/services/unifi-native/default.nix"
    "${configDir}/modules/nixos/services/netbird/default.nix"
  ];

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  nix.settings.require-sigs = false;
  # Prefer remote builders, but keep a local fallback for small activation-time
  # derivations when the configured builder is unavailable.
  nix.settings.max-jobs = 1;
  alc.distributedBuildClient.enable = true;

  services.journald.extraConfig = ''
    Storage=persistent
    SystemMaxUse=200M
  '';

  zramSwap.enable = true;

  services.netbird.managed.enable = true;

  sops.secrets = {
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

  systemd.services.unbound = {
    after = [
      "network-online.target"
      "time-sync.target"
    ];
    wants = [
      "network-online.target"
      "time-sync.target"
    ];
  };

  services.pihole-native = {
    enable = true;
    listenInterface = "end0";
    hostName = "pihole.rpi0.local";
    webPort = 8081;
    upstream = "127.0.0.1#5335";
    stateDirectory = "/var/lib/pihole/etc";
    passwordFile = config.sops.secrets.pihole_secret_key.path;
    disableWebPassword = true;
    webAcl = "+10.42.0.0/16,+192.168.1.10,+192.168.1.13,+192.168.1.15,+192.168.1.16";
  };

  services.unifi-native = {
    enable = true;
    role = "standby";
    openFirewall = true;
    maximumJavaHeapSize = 768;
  };

  networking.hosts."192.168.1.250" = ["k8s-api.local"];
}
