# nix-config/hosts/rpi0/configuration.nix
{
  config,
  pkgs,
  inputs,
  username,
  lib,
  configDir,
  ...
}: let
  steamHeadlessStartCommand = ''
    ${
      lib.escapeShellArgs [
        "${pkgs.openssh}/bin/ssh"
        "-o"
        "BatchMode=yes"
        "-o"
        "ConnectTimeout=5"
      ]
    } -o "Hostname=$COUCH_STREAM_START_TARGET" -o HostKeyAlias=xyz xyz ${lib.escapeShellArg "bash -lc ${lib.escapeShellArg "cd /home/alc/src/infra/gitops/docker/xyz/steam && docker compose up -d"}"}
  '';
in {
  imports = [
    ./hardware-configuration.nix
    "${configDir}/modules/nixos/common/default.nix"
    "${configDir}/modules/nixos/common/server.nix"
    "${configDir}/modules/nixos/profiles/nixbox-client/default.nix"
    "${configDir}/modules/nixos/services/pihole-native/default.nix"
    "${configDir}/modules/nixos/services/unifi-native/default.nix"
    "${configDir}/modules/nixos/services/netbird/default.nix"
    "${configDir}/modules/nixos/services/bluetooth-audio-receiver/default.nix"
    inputs.nix-secrets.nixosModules.rpi0Private
  ];

  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
  boot.loader.generic-extlinux-compatible.configurationLimit = 2;
  boot.kernelPackages = pkgs.linuxPackages_latest;
  # Direct DRM sessions bypass Hyprland's monitor rule. Pin the single TV
  # connector to its proven EDID mode so EGLFS cannot select the preferred
  # 4K30 timing for a 1080p stream.
  boot.kernelParams = ["video=HDMI-A-1:1920x1080@60e"];

  nix.settings.require-sigs = false;
  # The embedded client only substitutes or receives builds from xyz. Failing
  # closed here prevents an unavailable builder from turning into a long,
  # thermally constrained local compile on the SD-card-backed host.
  nix.settings.max-jobs = 0;
  alc.distributedBuildClient = {
    enable = true;
    builders = ["xyz"];
  };

  # Keep the embedded fallback host small enough for its SD-card root.
  fonts.packages = lib.mkForce [];
  programs.nix-ld.enable = lib.mkForce false;
  programs.nix-ld.libraries = lib.mkForce [];
  services.pcscd.enable = lib.mkForce false;
  virtualisation.docker.enable = lib.mkForce false;
  environment.variables = {
    EDITOR = lib.mkForce "nano";
    VISUAL = lib.mkForce "nano";
  };

  services.bluetooth-audio-receiver = {
    enable = true;
    user = username;
    adapterName = "Nixbox";
    outputSinkName = "alsa_output.platform-sound.stereo-fallback";
  };

  services.pipewire.wireplumber.extraConfig."52-rpi0-nixbox-outputs" = {
    "monitor.alsa.rules" = [
      {
        matches = [{"node.name" = "alsa_output.platform-hdmi-sound.stereo-fallback";}];
        actions."update-props" = {
          "node.description" = "Bedroom TV";
          "node.nick" = "Bedroom TV";
          "priority.session" = 1100;
        };
      }
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

  services.nixbox-client = {
    enable = true;
    user = username;
    enableBootSplash = false;
    outputMode = "1920x1080@60";
  };

  services.moonlight-client = {
    streamHost = "SteamHeadless";
    streamApplication = "Steam Big Picture";
    enableDirectDrmStream = true;
    # SteamHeadless renders at 1440p while the direct DRM client scales it onto
    # the RPi's fixed 1080p60 TV output.
    directDrmStreamArguments = ["--1440"];
    streamHostStartCommand = steamHeadlessStartCommand;
    streamReadinessHost = "xyz";
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
      "HEVC"
      "--video-decoder"
      "hardware"
      "--no-hdr"
      "--frame-pacing"
      "--swap-gamepad-buttons"
      "--mute-on-focus-loss"
      "--no-background-gamepad"
    ];

    browserStreamHost = "Wolf";
    browserStreamApplication = "Helium";
    browserStreamSelectorApplication = "Wolf UI";
    browserStreamSelectorProfileDirectory = "/home/${username}/.local/share/moonlight-client/private";
    # Browser runners are resumable across clients and are standardized on a
    # 1440p desktop. Keep that stream coordinate space even on the 1080p TV;
    # Moonlight scales presentation locally while absolute pointer input still
    # reaches every remote pixel. Steam retains the 1080p base arguments.
    browserStreamArguments = [
      "--1440"
      "--absolute-mouse"
      "--capture-system-keys"
      "never"
    ];
    browserStreamLayoutCommand = ''
      case "$COUCH_STREAM_APPLICATION" in
        Helium) runners=(WolfHelium) ;;
        "Wolf UI")
          runners=(
            WolfHeliumPrivate
            WolfBrave
            WolfChromium
            WolfFirefox
            WolfZen
          )
          ;;
        *) exit 0 ;;
      esac
      ${lib.getExe pkgs.openssh} \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        xev \
        wolf-stream-layout \
          --presentation-scale "$COUCH_PRESENTATION_SCALE" \
          "$COUCH_KEYBOARD_LAYOUT" \
          "''${runners[@]}"
    '';
  };

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
