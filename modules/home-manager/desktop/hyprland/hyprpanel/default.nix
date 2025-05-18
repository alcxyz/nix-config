{
  options
, config
, lib
, pkgs
, inputs
, ...
}:
with lib;

let
  # Depend on the parent desktop.hyprland.enable option (handled by mkIf in the config block)
  parentCfg = config.desktop.hyprland;

  # Define options specific to this hyprpanel module, nested under desktop.hyprland
  cfg = config.desktop.hyprland.hyprpanel;

in
{
  options.desktop.hyprland.hyprpanel = with types; { # Define options nested under desktop.hyprland
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the Home Manager configuration for Hyprpanel.";
    };
    
    package = mkOption {
      type = types.package;
      default = pkgs.hyprpanel;
      defaultText = literalExpression "pkgs.hyprpanel";
      description = "The Hyprpanel package to use.";
    };
    
    settings = mkOption {
      type = types.attrs;
      default = {};
      description = "Configuration options for Hyprpanel.";
      example = literalExpression ''
        {
          position = "top";
          height = 30;
          modules-left = ["workspaces" "window"];
          modules-center = ["clock"];
          modules-right = ["battery" "network" "volume"];
        }
      '';
    };
    
    systemd = { # Nested option for systemd service enablement
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to auto-start Hyprpanel through systemd user service.";
      };
    };
  };

  # Apply configurations if this module is enabled (depends on parent Hyprland suite enablement)
  config = mkIf (parentCfg.enable && cfg.enable) {
    # Assert that Hyprland is enabled if Hyprpanel is enabled
    assertions = [
      {
        assertion = config.programs.hyprland.enable;
        message = "Hyprpanel requires Home Manager's programs.hyprland.enable to be set to true.";
      }
    ];

    # The hyprpanel package is installed via the system suite.
    # environment.systemPackages = [ cfg.package ]; # Remove as handled by system suite

    # Generate the configuration file
    # Use home.configFile directly instead of home-manager.users.${config.user.name} which is for user-level HM configs
    xdg.configFile."hyprpanel/config.json" = {
      text = builtins.toJSON cfg.settings;
    };

    # Systemd user service for auto-starting with Hyprland
    systemd.user.services.hyprpanel = mkIf cfg.systemd.enable {
      description = "Hyprpanel - a status panel for Hyprland";
      wantedBy = [ "hyprland-session.target" ];
      partOf = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/hyprpanel"; # Use package from options
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}