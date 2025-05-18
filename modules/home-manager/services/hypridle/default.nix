# modules/home-manager/services/hypridle/default.nix
{
  options, config, lib, pkgs, inputs, ...
}:
with lib;
let
  cfg = config.services.hypridle;
  settings = cfg.settings;
in
{
  options.services.hypridle = {
    enable = mkEnableOption "hypridle idle daemon";
    settings = {
      lockTimeout = mkOption {
        type = types.int;
        default = 300;
        description = "Time in seconds before the screen locks due to inactivity.";
      };
      dpmsTimeout = mkOption {
        type = types.int;
        default = 600;
        description = "Time in seconds before the screen turns off due to inactivity.";
      };
      lockCommand = mkOption {
        type = types.str;
        default = "${pkgs.hyprlock}/bin/hyprlock";
        description = "Command to run to lock the screen. Ensures hyprlock is a dependency.";
      };
      hyprctlCommand = mkOption {
        type = types.str;
        default = "${pkgs.hyprland}/bin/hyprctl";
        description = "Path to hyprctl command. Ensures hyprland is a dependency.";
      };
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ pkgs.hypridle ];

    home.configFile."hypr/hypridle.conf" = {
      text = '''
        general {
            lock_cmd = ${settings.lockCommand}
            before_sleep_cmd = ${settings.lockCommand}
            after_sleep_cmd = ${settings.hyprctlCommand} dispatch dpms on
        }
        listener {
            timeout = ${toString settings.lockTimeout}
            on-timeout = ${settings.lockCommand}
        }
        listener {
            timeout = ${toString settings.dpmsTimeout}
            on-timeout = ${settings.hyprctlCommand} dispatch dpms off
            on-resume = ${settings.hyprctlCommand} dispatch dpms on
        }
      ''';
      onChange = '''
        if command -v hypridle &> /dev/null; then
          hypridle reload
        elif [ -x "${pkgs.hypridle}/bin/hypridle" ]; then
          ${pkgs.hypridle}/bin/hypridle reload
        fi
      ''';
    };
    
    systemd.user.services.hypridle = {
      description = "Hypridle - Idle management daemon for Hyprland";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.hypridle}/bin/hypridle";
        Restart = "always";
        RestartSec = 3;
      };
    };
  };
}
