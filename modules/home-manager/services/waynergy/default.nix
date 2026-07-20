{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.waynergy;
  sessionLauncher = pkgs.writeShellScript "waynergy-session-launcher" ''
    set -eu

    manager_variable() {
      ${pkgs.systemd}/bin/systemctl --user show-environment \
        | ${pkgs.gnused}/bin/sed -n "s/^$1=//p" \
        | ${pkgs.coreutils}/bin/head -n 1
    }

    for _attempt in $(${pkgs.coreutils}/bin/seq 1 300); do
      runtime_dir="''${XDG_RUNTIME_DIR:-$(manager_variable XDG_RUNTIME_DIR)}"
      wayland_display="$(manager_variable WAYLAND_DISPLAY)"
      hyprland_signature="$(manager_variable HYPRLAND_INSTANCE_SIGNATURE)"

      if [ -n "$runtime_dir" ] \
        && [ -n "$wayland_display" ] \
        && [ -S "$runtime_dir/$wayland_display" ]; then
        export XDG_RUNTIME_DIR="$runtime_dir"
        export WAYLAND_DISPLAY="$wayland_display"
        if [ -n "$hyprland_signature" ]; then
          export HYPRLAND_INSTANCE_SIGNATURE="$hyprland_signature"
        fi
        exec ${cfg.package}/bin/waynergy
      fi

      ${pkgs.coreutils}/bin/sleep 0.1
    done

    echo "Wayland session environment did not become ready" >&2
    exit 1
  '';
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
        ExecStart = sessionLauncher;
        Environment = [
          "PATH=${lib.makeBinPath [cfg.package pkgs.wl-clipboard pkgs.coreutils pkgs.procps]}"
        ];
        Restart = "always";
        RestartSec = 3;
      };

      Install.WantedBy = ["graphical-session.target"];
    };
  };
}
