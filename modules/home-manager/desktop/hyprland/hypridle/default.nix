# modules/home-manager/desktop/hyprland/hypridle/default.nix
{
  options, config, lib, pkgs, inputs, ...
}:
with lib;
let
  # This module's activation is controlled by config.desktop.hyprland.hypridle.enable
  moduleEnableCfg = config.desktop.hyprland.hypridle;

  # Settings for hypridle are taken from config.desktop.hyprland.hypridle.settings
  # Defaults are specified in the options definition below.
  settings = config.desktop.hyprland.hypridle.settings;
in
{
  options.desktop.hyprland.hypridle = {
    # The 'enable' option itself (options.desktop.hyprland.hypridle.enable)
    # is defined in the parent module (hyprland/default.nix).
    # This submodule defines the 'settings' options under that path.
    settings = {
      lockTimeout = mkOption {
        type = types.int;
        default = 300; # Default value
        description = "Time in seconds before the screen locks due to inactivity.";
      };
      dpmsTimeout = mkOption {
        type = types.int;
        default = 600; # Default value
        description = "Time in seconds before the screen turns off due to inactivity.";
      };
      lockCommand = mkOption {
        type = types.str;
        default = "${pkgs.hyprlock}/bin/hyprlock"; # Default value
        description = "Command to run to lock the screen. Ensures hyprlock is a dependency.";
      };
      hyprctlCommand = mkOption {
        type = types.str;
        default = "${pkgs.hyprland}/bin/hyprctl"; # Default value
        description = "Path to hyprctl command. Ensures hyprland is a dependency.";
      };
    };
  };

  config = mkIf moduleEnableCfg.enable {
    # Ensure hypridle package is installed when this module is active
    home.packages = [ pkgs.hypridle ];

    home.configFile."hypr/hypridle.conf" = {
      text = ''
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
      '';
      onChange = ''
        # Ensure hypridle is in PATH or use full path from pkgs.hypridle
        if command -v hypridle &> /dev/null; then
          hypridle reload
        elif [ -x "${pkgs.hypridle}/bin/hypridle" ]; then
          ${pkgs.hypridle}/bin/hypridle reload
        fi
      '';
    };
    
    systemd.user.services.hypridle = {
      description = "Hypridle - Idle management daemon for Hyprland";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${pkgs.hypridle}/bin/hypridle"; # Use package path for robustness
        Restart = "always";
        RestartSec = 3;
      };
    };
  };
}
