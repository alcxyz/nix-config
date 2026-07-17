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
  boot.loader.generic-extlinux-compatible.configurationLimit = 2;
  boot.kernelPackages = pkgs.linuxPackages_latest;

  nix.settings.require-sigs = false;
  # Prefer remote builders, but keep a local fallback for small activation-time
  # derivations when the configured builder is unavailable.
  nix.settings.max-jobs = 1;
  alc.distributedBuildClient.enable = true;

  # Keep the embedded fallback host small enough for its SD-card root.
  fonts.packages = lib.mkForce [];
  programs.nix-ld.enable = lib.mkForce false;
  programs.nix-ld.libraries = lib.mkForce [];
  services.pcscd.enable = lib.mkForce false;
  security.rtkit.enable = lib.mkForce false;
  services.pipewire.enable = lib.mkForce false;
  services.pipewire.alsa.enable = lib.mkForce false;
  services.pipewire.alsa.support32Bit = lib.mkForce false;
  services.pipewire.pulse.enable = lib.mkForce false;
  services.pipewire.wireplumber.enable = lib.mkForce false;
  hardware.bluetooth.enable = lib.mkForce false;
  virtualisation.docker.enable = lib.mkForce false;

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

  # Bootstrap time without DNS so Unbound can validate DNSSEC after a cold boot.
  networking.timeServers = [
    "162.159.200.1"
    "162.159.200.123"
  ];

  systemd.services.dns-time-bootstrap = {
    description = "Wait for DNS-independent network time";
    # A failed dependency job is not retried when this restarting oneshot
    # eventually succeeds. Explicitly enqueue Pi-hole on success; its existing
    # requirement pulls in Unbound and preserves the intended start ordering.
    unitConfig.OnSuccess = ["pihole-ftl.service"];
    after = [
      "network-online.target"
      "systemd-timesyncd.service"
    ];
    wants = [
      "network-online.target"
      "systemd-timesyncd.service"
    ];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "dns-time-bootstrap" ''
        set -euo pipefail

        for _ in $(${pkgs.coreutils}/bin/seq 1 180); do
          if [[ -e /run/systemd/timesync/synchronized ]]; then
            exit 0
          fi

          ${pkgs.coreutils}/bin/sleep 1
        done

        echo "Network time did not synchronize before the DNS startup deadline" >&2
        exit 1
      '';
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 5;
      TimeoutStartSec = 190;
    };
  };

  systemd.services.unbound = {
    after = [
      "dns-time-bootstrap.service"
      "network-online.target"
      "time-sync.target"
    ];
    wants = [
      "network-online.target"
      "time-sync.target"
    ];
    requires = ["dns-time-bootstrap.service"];
  };

  services.pihole-native = {
    enable = true;
    listenInterface = "end0";
    hostName = "pihole.rpi0.local";
    webPort = 8081;
    upstream = "127.0.0.1#5335";
    rateLimitCount = 10000;
    rateLimitInterval = 60;
    stateDirectory = "/var/lib/pihole/etc";
    passwordFile = config.sops.secrets.pihole_secret_key.path;
    disableWebPassword = true;
    webAcl = "+10.42.0.0/16,+192.168.1.10,+192.168.1.13,+192.168.1.15,+192.168.1.16,+192.168.1.23,+192.168.1.24";
  };

  services.unifi-native = {
    enable = true;
    role = "standby";
    openFirewall = true;
    maximumJavaHeapSize = 768;
  };

  networking.hosts."192.168.1.250" = ["k8s-api.local"];
}
