{ options, config, lib, pkgs, ... }:
with lib;
with lib.custom;

let
  cfg = config.desktop.addons.hypridle;
    # Safely check if the hyprlock module is available
  hasHyprlock = hasAttr "hyprlock" config.services;
  # Use the lock-screen script if available, otherwise fall back to direct hyprlock
  defaultLockCommand = 
    if hasHyprlock && config.services.hyprlock.enable 
    then "/run/current-system/sw/bin/lock-screen"
    else "${pkgs.hyprlock}/bin/hyprlock";
in
{
  options.desktop.addons.hypridle = with types; {
    enable = mkBoolOpt false "Enable hypridle service for managing idle state actions like screen locking and turning off the screen.";
    
    package = mkOption {
      type = types.package;
      default = pkgs.hypridle;
      description = "The hypridle package to use";
    };
    
    lockTimeout = mkOption {
      type = types.int;
      default = 300;
      description = "Time in seconds before the screen locks due to inactivity";
    };
    
    dpmsTimeout = mkOption {
      type = types.int;
      default = 600;
      description = "Time in seconds before the screen turns off due to inactivity";
    };
    
    lockCommand = mkOption {
      type = types.str;
      default = defaultLockCommand;
      description = "Command to run to lock the screen";
    };

    hyprctlCommand = mkOption {
      type = types.str;
      default = "${pkgs.hyprland}/bin/hyprctl";
      description = "Path to hyprctl command";
    };
  };

  config = mkIf cfg.enable {
    # Install packages
    environment.systemPackages = [ cfg.package ];
    
    # Create default configurations
    home.configFile."hypr/hypridle.conf" = {
      text = ''
        general {
            lock_cmd = ${cfg.lockCommand}
            before_sleep_cmd = ${cfg.lockCommand}
            after_sleep_cmd = ${cfg.hyprctlCommand} dispatch dpms on
        }

        listener {
            timeout = ${toString cfg.lockTimeout}
            on-timeout = ${cfg.lockCommand}
        }

        listener {
            timeout = ${toString cfg.dpmsTimeout}
            on-timeout = ${cfg.hyprctlCommand} dispatch dpms off
            on-resume = ${cfg.hyprctlCommand} dispatch dpms on
        }
      '';
      onChange = ''
        if [[ -x "${cfg.package}/bin/hypridle" ]]; then
          ${cfg.package}/bin/hypridle reload
        fi
      '';
    };
    
    # Set up systemd user service for hypridle
    systemd.user.services.hypridle = {
      description = "Hypridle - Idle management daemon for Hyprland";
      wantedBy = [ "graphical-session.target" ];
      partOf = [ "graphical-session.target" ];
      serviceConfig = {
        Type = "simple";
        ExecStart = "${cfg.package}/bin/hypridle";
        Restart = "always";
        RestartSec = 3;
      };
    };
  };
}

