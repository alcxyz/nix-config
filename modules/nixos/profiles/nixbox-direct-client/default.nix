{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.nixbox-direct-client;
  tvLabel =
    if cfg.room == null
    then "TV"
    else "${cfg.room} TV";
in {
  imports = [
    ../../services/moonlight-client/default.nix
    ../../services/bluetooth-audio-receiver/default.nix
    ../../services/steam-headless-remote/default.nix
  ];

  options.services.nixbox-direct-client = {
    enable = lib.mkEnableOption "a direct-DRM-only Moonlight TV appliance";

    user = lib.mkOption {
      type = lib.types.str;
      description = "Existing user that owns the direct-display session.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.moonlight-v4l2-request;
      defaultText = lib.literalExpression "pkgs.moonlight-v4l2-request";
      description = "Moonlight package used by the direct-display client.";
    };

    enableKdeConnect = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable KDE Connect input for direct-display sessions.";
    };

    streamFps = lib.mkOption {
      type = lib.types.ints.between 1 120;
      default = 60;
      description = "Requested Moonlight frame rate for direct-display streams.";
    };

    room = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "Living room";
      description = ''
        Room the appliance's TV is in. It names the TV audio output
        ("<room> TV") and the Bluetooth receiver ("Nixbox <room>").
      '';
    };

    tvConnector = lib.mkOption {
      type = lib.types.str;
      default = "HDMI-A-1";
      description = "DRM connector of the TV.";
    };

    tvAudioNode = lib.mkOption {
      type = lib.types.str;
      example = "alsa_output.platform-hdmi-sound.stereo-fallback";
      description = "PipeWire node name of the TV's HDMI audio sink.";
    };

    bluetoothAudio = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Receive Bluetooth audio from phones and play it on this appliance.";
      };

      outputSinkName = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          PipeWire sink that always receives Bluetooth audio. When unset, it
          follows the default sink, normally the TV.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.hasAttr cfg.user config.users.users;
        message = "services.nixbox-direct-client.user must name a declared NixOS user";
      }
    ];

    users.users.${cfg.user}.extraGroups = [
      "input"
      "render"
      "video"
    ];

    hardware.graphics.enable = true;
    hardware.enableRedistributableFirmware = true;

    services.greetd.enable = true;

    # These appliances receive complete closures built on xyz or xev. Fail
    # closed instead of falling back to slow, thermally constrained local
    # builds on an SD-card-backed host.
    nix.settings = {
      max-jobs = 0;
      require-sigs = false;
    };

    # Keep SD-card roots small: no desktop fonts, foreign-binary loader,
    # smart-card daemon or container runtime.
    fonts.packages = lib.mkForce [];
    programs.nix-ld.enable = lib.mkForce false;
    programs.nix-ld.libraries = lib.mkForce [];
    services.pcscd.enable = lib.mkForce false;
    virtualisation.containers.enable = lib.mkForce false;
    virtualisation.docker.enable = lib.mkForce false;

    environment.variables = {
      EDITOR = lib.mkForce "nano";
      VISUAL = lib.mkForce "nano";
    };

    services.journald.settings.Journal = {
      Storage = "persistent";
      SystemMaxUse = lib.mkDefault "100M";
    };

    zramSwap.enable = true;

    # Static SD-card host: fewer rollback anchors are enough (ADR-0013).
    alc.nix.keepGenerations = 3;

    services.steam-headless-remote = {
      enable = true;
      inherit (cfg) user;
    };

    services.bluetooth-audio-receiver = lib.mkIf cfg.bluetoothAudio.enable {
      enable = true;
      inherit (cfg) user;
      adapterName =
        if cfg.room == null
        then "Nixbox ${config.networking.hostName}"
        else "Nixbox ${cfg.room}";
      inherit (cfg.bluetoothAudio) outputSinkName;
    };

    services.pipewire.wireplumber.extraConfig."52-nixbox-tv-output" = {
      "monitor.alsa.rules" = [
        {
          matches = [{"node.name" = cfg.tvAudioNode;}];
          actions."update-props" = {
            "node.description" = tvLabel;
            "node.nick" = tvLabel;
            "priority.session" = 1100;
          };
        }
      ];
    };

    services.moonlight-client = {
      enable = true;
      enableCompositedSession = false;
      package = cfg.package;
      autoLoginUser = cfg.user;

      autoStartBrowser = false;
      autoStartStream = false;
      enableLocalBrowser = false;
      enableLocalUtilities = false;
      enableDms = false;
      enableMergedProfile = false;
      enableKdeConnect = cfg.enableKdeConnect;
      enableControllerShortcuts = false;
      enableAudioOutputCycle = false;
      enableAudioHealthRecovery = false;
      fallbackBrowserPackage = null;
      protectedBrowserPackage = null;

      enableDirectDrmBrowserStreams = true;
      enableDirectDrmStream = true;
      enableDirectModeInputShortcuts = true;
      defaultSessionMode = "direct-browser";
      relaunchOnExit = false;

      directDrmAudioOutputByConnector.${cfg.tvConnector} = tvLabel;

      streamHost = "SteamHeadless";
      streamApplication = "Steam Big Picture";
      streamReadinessHost = "xyz";

      browserStreamHost = "Wolf";
      browserStreamSelectorHost = "Wolf User";
      browserStreamSelectorPort = 48989;
      browserStreamSelectorApplication = "Wolf UI";
      browserStreamSelectorProfileDirectory = "/home/${cfg.user}/.local/share/moonlight-client/private";
      browserAbsoluteMouseSensitivity = 2.0;
      browserAbsoluteMousePollIntervalMs = 1;
    };
  };
}
