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
    inputs.nix-secrets.nixosModules.rpi0Hardware
    "${configDir}/modules/nixos/common/default.nix"
    "${configDir}/modules/nixos/common/server.nix"
    "${configDir}/modules/nixos/profiles/nixbox-direct-client/default.nix"
    "${configDir}/modules/nixos/services/pihole-native/default.nix"
    "${configDir}/modules/nixos/services/netbird/default.nix"
    inputs.nix-secrets.nixosModules.rpi0Private
  ];

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.loader.generic-extlinux-compatible.configurationLimit = 2;
  boot.kernelPackages = pkgs.linuxPackages_latest;
  # Pin the single TV connector to its proven EDID mode so EGLFS cannot select
  # the preferred 4K30 timing for a 1080p stream.
  boot.kernelParams = ["video=HDMI-A-1:1920x1080@60e"];

  alc.distributedBuildClient = {
    enable = true;
    builders = ["xyz"];
  };

  # The analog jack feeds the sound system, which also receives Bluetooth
  # audio from phones (bluetoothAudio.outputSinkName below).
  services.pipewire.wireplumber.extraConfig."52-rpi0-analog-output" = {
    "monitor.alsa.rules" = [
      {
        matches = [{"node.name" = "alsa_output.platform-sound.stereo-fallback";}];
        actions."update-props" = {
          "node.description" = "Bose sound system";
          "node.nick" = "Bose sound system";
          "priority.session" = 1000;
        };
      }
    ];
  };

  hardware.firmware = [pkgs.broadcom-bt-firmware];

  # Direct-DRM appliance only: Moonlight owns the display for the Wolf browser
  # and Steam streams, with no composited session, Hyprland or DMS.
  services.nixbox-direct-client = {
    enable = true;
    user = username;
    room = "Living room";
    tvAudioNode = "alsa_output.platform-hdmi-sound.stereo-fallback";
    bluetoothAudio.outputSinkName = "alsa_output.platform-sound.stereo-fallback";
  };

  services.moonlight-client = {
    directDrmFixedOutput = {
      device = "/dev/dri/card0";
      connector = "HDMI-A-1";
      mode = "1920x1080@60";
    };
    # SteamHeadless renders at 1440p while the direct DRM client scales it onto
    # the RPi's fixed 1080p60 TV output.
    directDrmStreamArguments = ["--1440"];
    streamArguments = [
      "--1080"
      "--fps"
      "60"
      "--bitrate"
      "40000"
      "--display-mode"
      "windowed"
      "--audio-config"
      "stereo"
      "--video-codec"
      "H.264"
      "--video-decoder"
      "hardware"
      "--no-hdr"
      "--frame-pacing"
      "--swap-gamepad-buttons"
      "--mute-on-focus-loss"
      "--no-background-gamepad"
    ];

    # Join the single persistent cooperative Helium desktop. Wolf's producer
    # reset path recovers direct-DRM consumers across initial joins, reconnects,
    # and worker handoff without spawning a second browser runner.
    browserStreamApplication = "Helium";
    # Browser runners are resumable across clients. Keep rpi0's browser stream
    # at the same 1080p resolution as its fixed TV output.
    browserStreamArguments = [
      "--absolute-mouse"
      "--capture-system-keys"
      "never"
    ];
  };

  services.journald.settings.Journal.SystemMaxUse = "200M";

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

  networking.hosts."192.168.1.250" = ["k8s-api.local"];
}
