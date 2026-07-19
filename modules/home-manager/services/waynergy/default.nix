{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.waynergy;
in {
  options.services.waynergy = {
    enable = lib.mkEnableOption "Waynergy Synergy client for Wayland";

    package = lib.mkPackageOption pkgs "waynergy" {};

    serverAddress = lib.mkOption {
      type = lib.types.str;
      default = "mac";
      description = "Hostname or address of the Synergy server.";
    };

    screenName = lib.mkOption {
      type = lib.types.str;
      description = "Stable screen name presented to the Synergy server.";
    };

    sourceKeyboard = lib.mkOption {
      type = lib.types.enum ["standard" "mac"];
      default = "standard";
      description = "Physical keycode layout used by the server computer.";
    };

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Start Waynergy with the graphical session.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [cfg.package];

    xdg.configFile =
      {
        "waynergy/config.ini".text = ''
          host = ${cfg.serverAddress}
          name = ${cfg.screenName}
          backend = wlr
          restart_on_fatal = true
          ${lib.optionalString (cfg.sourceKeyboard == "mac") "xkb_key_offset = 7"}

          [idle-inhibit]
          enable = false

          [tls]
          enable = true
          tofu = true

          [log]
          level = 3
        '';
      }
      // lib.optionalAttrs (cfg.sourceKeyboard == "mac") {
        "waynergy/xkb_keymap".source = ./xkb-keymap-mac;
      };

    systemd.user.services.waynergy = lib.mkIf cfg.autoStart {
      Unit = {
        Description = "Waynergy Synergy client";
        After = ["graphical-session.target"];
        PartOf = ["graphical-session.target"];
      };

      Service = {
        ExecStart = "${cfg.package}/bin/waynergy";
        Environment = [
          "PATH=${lib.makeBinPath [cfg.package pkgs.wl-clipboard pkgs.coreutils pkgs.procps]}"
        ];
        Restart = "on-failure";
        RestartSec = 3;
      };

      Install.WantedBy = ["graphical-session.target"];
    };
  };
}
