# modules/home-manager/services/hypridle/default.nix
{
  options, config, lib, pkgs, ...
}:
with lib;
let
  # cfg now refers to your module's specific, namespaced options
  cfg = config.services.hypridle.managed;
in
{
  # These are the options your module EXPOSES for configuration
  options.services.hypridle.managed = {
    enable = mkEnableOption "hypridle idle daemon (via managed service module)";

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
      default = "${pkgs.hyprlock}/bin/hyprlock"; # Assumes hyprlock is available
      description = "Command to run to lock the screen.";
    };
    hyprctlCommand = mkOption {
      type = types.str;
      default = "${pkgs.hyprland}/bin/hyprctl"; # Assumes hyprland is available
      description = "Path to hyprctl command.";
    };
  };

  # This section applies the configuration if your managed module is enabled
  config = mkIf cfg.enable {
    # Enable and configure the *standard* Home Manager hypridle service
    services.hypridle = {
      enable = true; # This enables the built-in HM service for hypridle

      # Construct the 'settings' attrset as expected by the standard hypridle module
      settings = {
        general = {
          lock_cmd = cfg.lockCommand;
          before_sleep_cmd = cfg.lockCommand;
          after_sleep_cmd = "${cfg.hyprctlCommand} dispatch dpms on";
        };
        listener = [
          {
            timeout = toString cfg.lockTimeout; # Values in INI are strings
            on-timeout = cfg.lockCommand;
          }
          {
            timeout = toString cfg.dpmsTimeout; # Values in INI are strings
            on-timeout = "${cfg.hyprctlCommand} dispatch dpms off";
            on-resume = "${cfg.hyprctlCommand} dispatch dpms on";
          }
        ];
      };
    };

    # The standard services.hypridle module handles:
    # - Adding pkgs.hypridle to home.packages
    # - Creating home.configFile."hypr/hypridle.conf"
    # - Creating and managing the systemd.user.services.hypridle unit
  };
}

