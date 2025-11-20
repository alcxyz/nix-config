{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.services.idleAutostart;
  hyprCtl = "${pkgs.hyprland}/bin/hyprctl";
  hypridle = "${pkgs.hypridle}/bin/hypridle";
  swayidle = "${pkgs.swayidle}/bin/swayidle";
  wlr = "${pkgs.wlr-randr}/bin/wlr-randr";
  hyprlock = "${pkgs.hyprlock}/bin/hyprlock";
  inhibit = "${pkgs.systemd}/bin/systemd-inhibit --what=sleep:idle --why=Idle/DPMS";
in
{
  options.services.idleAutostart = {
    enable = mkEnableOption "Install idle-autostart script and optional XDG autostart entry";

    lockTimeout = mkOption {
      type = types.int;
      default = 300;
      description = "Seconds before locking.";
    };

    dpmsTimeout = mkOption {
      type = types.int;
      default = 600;
      description = "Seconds before DPMS off.";
    };

    dpmsOffCommand = mkOption {
      type = types.str;
      default = "${wlr} --output DP-1 --off";
      description = "Command to turn off displays (wlroots).";
    };
    dpmsOnCommand = mkOption {
      type = types.str;
      default = "${wlr} --output DP-1 --on";
      description = "Command to turn on displays (wlroots).";
    };

    xdgAutostart.enable = mkOption {
      type = types.bool;
      default = false;
      description = "Install an XDG autostart .desktop that runs the script.";
    };
  };

  config = mkIf cfg.enable {
    home.file.".local/bin/idle-autostart.sh" = {
      executable = true;
      text = ''
        #!/usr/bin/env bash
        set -euo pipefail

        # Fixed values from Nix config
        LOCK_T='${toString cfg.lockTimeout}'
        DPMS_T='${toString cfg.dpmsTimeout}'
        DPMS_OFF='${cfg.dpmsOffCommand}'
        DPMS_ON='${cfg.dpmsOnCommand}'

        comp="$XDG_CURRENT_DESKTOP"
        if [ -z "$comp" ]; then
          comp="$XDG_SESSION_DESKTOP"
        fi
        comp_lc="$(printf '%s' "$comp" | tr 'A-Z' 'a-z' || true)"

        way="$WAYLAND_DISPLAY"
        way_print="$way"
        if [ -z "$way_print" ]; then
          way_print='<none>'
        fi

        echo "idle-autostart: compositor=$comp_lc wayland=$way_print (lock=${toString cfg.lockTimeout}s, dpms=${toString cfg.dpmsTimeout}s)"

        if [ -z "$way" ]; then
          # Not Wayland, do nothing
          exit 0
        fi

        if printf '%s' "$comp_lc" | grep -q hyprland; then
          tmpcfg="$(mktemp)"
          trap 'rm -f "$tmpcfg"' EXIT
          cat >"$tmpcfg" <<EOF
        general {
          lock_cmd = ${hyprlock}
          before_sleep_cmd = ${hyprlock}
          after_sleep_cmd = ${hyprCtl} dispatch dpms on
        }
        listener {
          timeout = ${toString cfg.lockTimeout}
          on-timeout = ${hyprlock}
        }
        listener {
          timeout = ${toString cfg.dpmsTimeout}
          on-timeout = ${hyprCtl} dispatch dpms off
          on-resume = ${hyprCtl} dispatch dpms on
        }
EOF
          exec ${inhibit} ${hypridle} -q -c "$tmpcfg"
        else
          # wlroots path: niri, mangowc, sway, etc.
          exec ${inhibit} ${swayidle} -w \
            timeout "$LOCK_T" bash -lc '${hyprlock}' \
            timeout "$DPMS_T" bash -lc '${cfg.dpmsOffCommand}' \
            resume          bash -lc '${cfg.dpmsOnCommand}' \
            before-sleep    bash -lc '${hyprlock}'
        fi
      '';
    };

    xdg.desktopEntries = mkIf cfg.xdgAutostart.enable {
      idle-autostart = {
        name = "Idle Autostart";
        comment = "Start idle daemon per compositor (hypridle or swayidle)";
        exec = "${config.home.homeDirectory}/.local/bin/idle-autostart.sh";
        terminal = false;
        type = "Application";
        categories = [ "Utility" ];
      };
    };
  };
}
