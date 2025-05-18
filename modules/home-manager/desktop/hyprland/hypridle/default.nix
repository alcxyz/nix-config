{
  options
, config
, lib
, pkgs
, ...
}:
with lib;

let
  # Depend on the parent desktop.hyprland.enable option
  parentCfg = config.desktop.hyprland;

  # Safely check if the hyprlock submodule is available and enabled
  # Assumes hyprlock submodule defines programs.hyprlock.enable or similar
  # and is imported *before* this module in the parent.
  # For now, we'll rely on the parent bringing in the hyprlock module.
  # A more robust way might be to check if the hyprlock option set is available in config.
  # Let's assume config.programs.hyprlock.enable exists if the hyprlock module is imported.
  hasHyprlockModule = hasAttrByPath ["programs" "hyprlock"] config;
  hyprlockEnabled = hasHyprlockModule && config.programs.hyprlock.enable;

  # Use the lock-screen command if hyprlock module defines it, otherwise fall back to hyprlock binary
  # Assumes hyprlock module defines programs.hyprlock.lockCommand if it provides a script.
  # If not, default to the hyprlock binary.
  defaultLockCommand = 
    if hasHyprlockModule && hasAttrByPath ["programs" "hyprlock" "lockCommand"] config && hyprlockEnabled
    then config.programs.hyprlock.lockCommand
    else "${pkgs.hyprlock}/bin/hyprlock";

  cfg = config.programs.hypridle; # Define options.programs.hypridle for consistency if needed, but module uses parent enable
in
{
  options.programs.hypridle = with types; { # Define options for this module's specific settings
    enable = mkOption { # This enable is for this specific module's configuration set
      type = types.bool;
      default = false;
      description = "Enable Home Manager configuration for hypridle. Requires the parent desktop.hyprland module to be enabled.";
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
      # Default to the command derived from hyprlock module if available, otherwise hyprlock binary.
      default = defaultLockCommand;
      description = "Command to run to lock the screen";
    };

    hyprctlCommand = mkOption {
      type = types.str;
      default = "${pkgs.hyprland}/bin/hyprctl";
      description = "Path to hyprctl command";
    };
  };

  # Apply configurations if this module *and* the parent Hyprland suite are enabled
  config = mkIf (parentCfg.enable && cfg.enable) {
    # hypridle package should be installed at the system level (already added).
    # environment.systemPackages = [ pkgs.hypridle ];
    
    # Configure hypridle configuration file via Home Manager
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
      # The onChange reload might require hypridle binary in path or full path
      onChange = ''
        if command -v hypridle &> /dev/null; then
          hypridle reload
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
        ExecStart = "${pkgs.hypridle}/bin/hypridle"; # Use full package path
        Restart = "always";
        RestartSec = 3;
      };
    };
  };
}