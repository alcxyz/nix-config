{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.moonlightWolfClient;
  endpointAddress =
    if cfg.address == null
    then "127.0.0.1"
    else cfg.address;
  publicEndpointAddress =
    if cfg.public.address == null
    then "127.0.0.1"
    else cfg.public.address;
  moonlightPackage = cfg.package.overrideAttrs (old: {
    patches =
      (old.patches or [])
      ++ [
        ../../../nixos/services/moonlight-client/patches/poll-absolute-mouse.patch
        ../../../nixos/services/moonlight-client/patches/forward-media-keys.patch
      ];
  });
  mkMoonlight = name: profileDirectory:
    pkgs.writeShellApplication {
      inherit name;
      runtimeInputs = [pkgs.coreutils];
      text = ''
        install -d -m 0700 \
          ${lib.escapeShellArg "${profileDirectory}/config"} \
          ${lib.escapeShellArg "${profileDirectory}/cache"} \
          ${lib.escapeShellArg "${profileDirectory}/data"}
        export XDG_CONFIG_HOME=${lib.escapeShellArg "${profileDirectory}/config"}
        export XDG_CACHE_HOME=${lib.escapeShellArg "${profileDirectory}/cache"}
        export XDG_DATA_HOME=${lib.escapeShellArg "${profileDirectory}/data"}
        exec ${lib.getExe moonlightPackage} "$@"
      '';
    };
  moonlight = mkMoonlight "moonlight-wolf-client" cfg.profileDirectory;
  publicMoonlight = mkMoonlight "moonlight-wolf-public-client" cfg.public.profileDirectory;
  reconcileEndpoint = pkgs.writeShellApplication {
    name = "moonlight-wolf-reconcile-endpoint";
    runtimeInputs = [pkgs.python3];
    text = ''
      config_file=${lib.escapeShellArg "${cfg.profileDirectory}/config/Moonlight Game Streaming Project/Moonlight.conf"}
      if [ ! -f "$config_file" ]; then
        echo "Moonlight is not paired with ${cfg.hostname}; run ${cfg.pairCommandName} FOUR_DIGIT_PIN first" >&2
        exit 1
      fi
      exec python3 ${../../../nixos/services/moonlight-client/reconcile-endpoints.py} \
        "$config_file" \
        ${lib.escapeShellArg cfg.hostname} \
        lan-only \
        ${lib.escapeShellArg endpointAddress} \
        ${lib.escapeShellArg endpointAddress} \
        ${lib.escapeShellArg (toString cfg.port)} \
        ""
    '';
  };
  reconcilePublicEndpoint = pkgs.writeShellApplication {
    name = "moonlight-wolf-public-reconcile-endpoint";
    runtimeInputs = [pkgs.python3];
    text = ''
      config_file=${lib.escapeShellArg "${cfg.public.profileDirectory}/config/Moonlight Game Streaming Project/Moonlight.conf"}
      if [ ! -f "$config_file" ]; then
        echo "Moonlight is not paired with ${cfg.public.hostname}; run ${cfg.public.pairCommandName} FOUR_DIGIT_PIN first" >&2
        exit 1
      fi
      exec python3 ${../../../nixos/services/moonlight-client/reconcile-endpoints.py} \
        "$config_file" \
        ${lib.escapeShellArg cfg.public.hostname} \
        lan-only \
        ${lib.escapeShellArg publicEndpointAddress} \
        ${lib.escapeShellArg publicEndpointAddress} \
        ${lib.escapeShellArg (toString cfg.public.port)} \
        ""
    '';
  };
  launcher = pkgs.writeShellApplication {
    name = cfg.commandName;
    text = ''
      ${lib.getExe reconcileEndpoint}
      exec ${pkgs.coreutils}/bin/env \
        QT_QPA_PLATFORM=${lib.escapeShellArg cfg.qtPlatform} \
        MOONLIGHT_POLL_ABSOLUTE_MOUSE=1 \
        MOONLIGHT_ABSOLUTE_MOUSE_POLL_INTERVAL_MS=${toString cfg.absoluteMousePollIntervalMs} \
        MOONLIGHT_ABSOLUTE_MOUSE_SENSITIVITY=${toString cfg.absoluteMouseSensitivity} \
        MOONLIGHT_SHOW_LOCAL_CURSOR=1 \
        ${lib.getExe moonlight} \
        stream \
        ${lib.escapeShellArgs (
        cfg.arguments
        ++ lib.optionals (cfg.videoCodec != null) ["--video-codec" cfg.videoCodec]
        ++ lib.optionals (cfg.bitrateKbps != null) ["--bitrate" (toString cfg.bitrateKbps)]
      )} \
        ${lib.escapeShellArg "${endpointAddress}:${toString cfg.port}"} \
        ${lib.escapeShellArg cfg.application}
    '';
  };
  pair = pkgs.writeShellApplication {
    name = cfg.pairCommandName;
    text = ''
      if [ "$#" -ne 1 ] || ! [[ "$1" =~ ^[0-9]{4}$ ]]; then
        echo "usage: ${cfg.pairCommandName} FOUR_DIGIT_PIN" >&2
        exit 2
      fi
      exec ${pkgs.coreutils}/bin/env \
        QT_QPA_PLATFORM=${lib.escapeShellArg cfg.qtPlatform} \
        ${lib.getExe moonlight} \
        pair \
        --pin "$1" \
        ${lib.escapeShellArg "${endpointAddress}:${toString cfg.port}"}
    '';
  };
  desktopItem = pkgs.makeDesktopItem {
    name = cfg.commandName;
    desktopName = cfg.desktopName;
    comment = "Open the protected Wolf browser selector over the local network";
    exec = lib.getExe launcher;
    icon = "moonlight";
    categories = [
      "Game"
      "Network"
    ];
  };
  publicLauncher = pkgs.writeShellApplication {
    name = cfg.public.commandName;
    text = ''
      ${lib.getExe reconcilePublicEndpoint}
      exec ${pkgs.coreutils}/bin/env \
        QT_QPA_PLATFORM=${lib.escapeShellArg cfg.public.qtPlatform} \
        MOONLIGHT_POLL_ABSOLUTE_MOUSE=1 \
        MOONLIGHT_ABSOLUTE_MOUSE_POLL_INTERVAL_MS=${toString cfg.absoluteMousePollIntervalMs} \
        MOONLIGHT_ABSOLUTE_MOUSE_SENSITIVITY=${toString cfg.absoluteMouseSensitivity} \
        MOONLIGHT_SHOW_LOCAL_CURSOR=1 \
        ${lib.getExe publicMoonlight} \
        stream \
        ${lib.escapeShellArgs (
        cfg.public.arguments
        ++ lib.optionals (cfg.public.videoCodec != null) ["--video-codec" cfg.public.videoCodec]
        ++ lib.optionals (cfg.public.bitrateKbps != null) ["--bitrate" (toString cfg.public.bitrateKbps)]
      )} \
        ${lib.escapeShellArg "${publicEndpointAddress}:${toString cfg.public.port}"} \
        ${lib.escapeShellArg cfg.public.application}
    '';
  };
  publicPair = pkgs.writeShellApplication {
    name = cfg.public.pairCommandName;
    text = ''
      if [ "$#" -ne 1 ] || ! [[ "$1" =~ ^[0-9]{4}$ ]]; then
        echo "usage: ${cfg.public.pairCommandName} FOUR_DIGIT_PIN" >&2
        exit 2
      fi
      exec ${pkgs.coreutils}/bin/env \
        QT_QPA_PLATFORM=${lib.escapeShellArg cfg.public.qtPlatform} \
        ${lib.getExe publicMoonlight} \
        pair \
        --pin "$1" \
        ${lib.escapeShellArg "${publicEndpointAddress}:${toString cfg.public.port}"}
    '';
  };
  publicDesktopItem = pkgs.makeDesktopItem {
    name = cfg.public.commandName;
    desktopName = cfg.public.desktopName;
    comment = "Open the shared Helium stream through Moonlight";
    exec = lib.getExe publicLauncher;
    icon = "helium";
    categories = [
      "Network"
      "WebBrowser"
    ];
  };
in {
  options.programs.moonlightWolfClient = {
    enable = lib.mkEnableOption "an explicit LAN-only Moonlight Wolf launcher";

    address = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Private LAN address of the Wolf coordinator.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = 48989;
      description = "Moonlight HTTP port of the Wolf coordinator.";
    };

    hostname = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "Wolf User";
      description = "Paired Moonlight host name expected in the isolated client profile.";
    };

    application = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "Wolf UI";
      description = "Wolf application selected by the launcher.";
    };

    profileDirectory = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.local/share/moonlight-client/private";
      description = "Independent Moonlight XDG profile containing the protected-host pairing.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.moonlight-qt;
      defaultText = lib.literalExpression "pkgs.moonlight-qt";
      description = "Moonlight package wrapped by the LAN launcher.";
    };

    qtPlatform = lib.mkOption {
      type = lib.types.enum [
        "wayland"
        "xcb"
      ];
      default = "xcb";
      description = "Qt display backend used by Moonlight.";
    };

    arguments = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "--1440"
        "--display-mode"
        "windowed"
        "--absolute-mouse"
        "--capture-system-keys"
        "never"
      ];
      description = "Arguments passed to Moonlight's stream command.";
    };

    videoCodec = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [
        "H.264"
        "HEVC"
        "AV1"
      ]);
      default = null;
      description = "Explicit video codec requested from Moonlight, or null to use its configured preference.";
    };

    bitrateKbps = lib.mkOption {
      type = lib.types.nullOr lib.types.ints.positive;
      default = null;
      description = "Explicit Moonlight video bitrate in kilobits per second, or null to use its configured preference.";
    };

    absoluteMousePollIntervalMs = lib.mkOption {
      type = lib.types.ints.positive;
      default = 1;
      description = "Polling interval for the bounded absolute-pointer compatibility path.";
    };

    absoluteMouseSensitivity = lib.mkOption {
      type = lib.types.numbers.positive;
      default = 1.0;
      description = "Sensitivity applied to the bounded absolute-pointer compatibility path.";
    };

    commandName = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "moonlight-wolf-ui-lan";
      description = "Command installed for launching Wolf UI.";
    };

    pairCommandName = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "moonlight-wolf-ui-pair";
      description = "Command installed for pairing the isolated Moonlight profile.";
    };

    desktopName = lib.mkOption {
      type = lib.types.nonEmptyStr;
      default = "Wolf UI (LAN)";
      description = "Desktop launcher name.";
    };

    public = {
      enable = lib.mkEnableOption "an isolated public Helium launcher";

      address = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = cfg.address;
        defaultText = lib.literalExpression "config.programs.moonlightWolfClient.address";
        description = "Private LAN address of the public Wolf coordinator.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 47989;
        description = "Moonlight HTTP port of the public Wolf coordinator.";
      };

      hostname = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "Wolf";
        description = "Paired Moonlight host providing the public stream.";
      };

      application = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "Helium";
        description = "Public Wolf application selected by the launcher.";
      };

      profileDirectory = lib.mkOption {
        type = lib.types.str;
        default = "${config.home.homeDirectory}/.local/share/moonlight-client/public";
        description = "Independent Moonlight XDG profile containing the public-host pairing.";
      };

      qtPlatform = lib.mkOption {
        type = lib.types.enum [
          "wayland"
          "xcb"
        ];
        default = "xcb";
        description = "Qt display backend used by the public launcher.";
      };

      arguments = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "--1080"
          "--display-mode"
          "windowed"
          "--absolute-mouse"
          "--capture-system-keys"
          "never"
        ];
        description = "Arguments passed to Moonlight's public stream command.";
      };

      videoCodec = lib.mkOption {
        type = lib.types.nullOr (lib.types.enum [
          "H.264"
          "HEVC"
          "AV1"
        ]);
        default = null;
        description = "Explicit video codec requested from the public Moonlight stream, or null to use its configured preference.";
      };

      bitrateKbps = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default = null;
        description = "Explicit public Moonlight video bitrate in kilobits per second, or null to use its configured preference.";
      };

      commandName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "helium-stream";
        description = "Command installed for launching public Helium.";
      };

      pairCommandName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "helium-pair";
        description = "Command installed for pairing the public Moonlight profile.";
      };

      desktopName = lib.mkOption {
        type = lib.types.nonEmptyStr;
        default = "Helium (Stream)";
        description = "Desktop launcher name for public Helium.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = pkgs.stdenv.hostPlatform.isLinux;
        message = "programs.moonlightWolfClient is currently supported only on Linux";
      }
      {
        assertion = cfg.address != null;
        message = "programs.moonlightWolfClient.address must be set by private host configuration";
      }
      {
        assertion = lib.hasPrefix "/" cfg.profileDirectory;
        message = "programs.moonlightWolfClient.profileDirectory must be absolute";
      }
      {
        assertion = !cfg.public.enable || lib.hasPrefix "/" cfg.public.profileDirectory;
        message = "programs.moonlightWolfClient.public.profileDirectory must be absolute";
      }
      {
        assertion = !cfg.public.enable || cfg.public.address != null;
        message = "programs.moonlightWolfClient.public.address must be set by private host configuration";
      }
      {
        assertion = !cfg.public.enable || cfg.public.profileDirectory != cfg.profileDirectory;
        message = "the public and protected Moonlight profiles must use different directories";
      }
    ];

    home.packages =
      [
        launcher
        pair
        desktopItem
      ]
      ++ lib.optionals cfg.public.enable [
        publicLauncher
        publicPair
        publicDesktopItem
      ];
  };
}
