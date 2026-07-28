{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.programs.moonlightWolfClient;
  endpointAddress = if cfg.address == null then "127.0.0.1" else cfg.address;
  moonlightPackage = cfg.package.overrideAttrs (old: {
    patches = (old.patches or [ ]) ++ [
      ../../../nixos/services/moonlight-client/patches/poll-absolute-mouse.patch
      ../../../nixos/services/moonlight-client/patches/forward-media-keys.patch
    ];
  });
  moonlight = pkgs.writeShellApplication {
    name = "moonlight-wolf-client";
    runtimeInputs = [ pkgs.coreutils ];
    text = ''
      install -d -m 0700 \
        ${lib.escapeShellArg "${cfg.profileDirectory}/config"} \
        ${lib.escapeShellArg "${cfg.profileDirectory}/cache"} \
        ${lib.escapeShellArg "${cfg.profileDirectory}/data"}
      export XDG_CONFIG_HOME=${lib.escapeShellArg "${cfg.profileDirectory}/config"}
      export XDG_CACHE_HOME=${lib.escapeShellArg "${cfg.profileDirectory}/cache"}
      export XDG_DATA_HOME=${lib.escapeShellArg "${cfg.profileDirectory}/data"}
      exec ${lib.getExe moonlightPackage} "$@"
    '';
  };
  reconcileEndpoint = pkgs.writeShellApplication {
    name = "moonlight-wolf-reconcile-endpoint";
    runtimeInputs = [ pkgs.python3 ];
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
        ${lib.escapeShellArgs cfg.arguments} \
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
in
{
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
        "--absolute-mouse"
        "--capture-system-keys"
        "never"
      ];
      description = "Arguments passed to Moonlight's stream command.";
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
    ];

    home.packages = [
      launcher
      pair
      desktopItem
    ];
  };
}
