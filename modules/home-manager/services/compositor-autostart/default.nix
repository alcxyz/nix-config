{ config, lib, pkgs, ... }:
with lib;
let
  cfg = config.services.compositorAutostart.managed;
in
{
  options.services.compositorAutostart.managed = {
    enable = mkEnableOption "Start compositor-specific daemons per session";
    lockTimeout = mkOption { type = types.int; default = 300; };
    dpmsTimeout = mkOption { type = types.int; default = 600; };
    lockCommand = mkOption {
      type = types.str;
      default = "${pkgs.hyprlock}/bin/hyprlock";
    };
    # Optional override hooks
    dpmsOffAll = mkOption {
      type = types.str;
      default = "${pkgs.wlr-randr}/bin/wlr-randr --off";
    };
    dpmsOnAll = mkOption {
      type = types.str;
      default = "${pkgs.wlr-randr}/bin/wlr-randr --on";
    };
    inhibitSleep = mkOption { type = types.bool; default = true; };
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      hypridle
      swayidle
      wlr-randr
      hyprlock
      bash
      coreutils
      systemd
    ];

    systemd.user.services.compositor-autostart = {
      Unit = {
        Description = "Start compositor-specific idle daemon";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        Type = "simple";
        Environment = [
          "LOCK_T=${toString cfg.lockTimeout}"
          "DPMS_T=${toString cfg.dpmsTimeout}"
          "LOCK_CMD=${cfg.lockCommand}"
          "DPMS_OFF_CMD=${cfg.dpmsOffAll}"
          "DPMS_ON_CMD=${cfg.dpmsOnAll}"
        ];
        ExecStart = let
          swayCmd = ''
            ${pkgs.swayidle}/bin/swayidle -w \
              --timeout "$LOCK_T" "$LOCK_CMD" \
              --timeout "$DPMS_T" "$DPMS_OFF_CMD" --resume "$DPMS_ON_CMD" \
              --before-sleep "$LOCK_CMD"
          '';
          hyprCmd = ''
            ${pkgs.hypridle}/bin/hypridle -q <<'EOF'
            general {
              lock_cmd = ${cfg.lockCommand}
              before_sleep_cmd = ${cfg.lockCommand}
              after_sleep_cmd = ${pkgs.hyprland}/bin/hyprctl dispatch dpms on
            }
            listener {
              timeout = ${toString cfg.lockTimeout}
              on-timeout = ${cfg.lockCommand}
            }
            listener {
              timeout = ${toString cfg.dpmsTimeout}
              on-timeout = ${pkgs.hyprland}/bin/hyprctl dispatch dpms off
              on-resume = ${pkgs.hyprland}/bin/hyprctl dispatch dpms on
            }
EOF
          '';
          wrapped = cmd:
            if cfg.inhibitSleep then
              "${pkgs.systemd}/bin/systemd-inhibit --what=sleep:idle --why='Idle/DPMS' ${cmd}"
            else
              cmd;
        in
          ''
            bash -eu -o pipefail -c '
              comp="${XDG_CURRENT_DESKTOP:-${XDG_SESSION_DESKTOP:-}}"
              comp_lc="$(printf "%s" "$comp" | tr A-Z a-z || true)"
              echo "compositor-autostart: XDG_CURRENT_DESKTOP=$comp"

              if echo "$comp_lc" | grep -q "hyprland"; then
                exec ${wrapped hyprCmd}
              fi

              # default path for wlroots compositors (niri, mangowc, sway, etc.)
              exec ${wrapped swayCmd}
            '
          '';
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
