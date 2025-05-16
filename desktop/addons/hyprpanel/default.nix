{ options
, config
, pkgs
, lib
, inputs
, ...
}:
with lib;
with lib.custom; let
  cfg = config.desktop.addons.hyprpanel;
  colors = (inputs.nix-colors.colorschemes.${builtins.toString config.desktop.colorscheme}).palette;
in
{
  options.desktop.addons.hyprpanel = with types; {
    enable = mkBoolOpt false "Enable or disable hyprpanel";
    
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
    
    systemd.enable = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to auto-start Hyprpanel through systemd user service.";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = config.programs.hyprland.enable;
        message = "Hyprpanel requires Hyprland to be enabled.";
      }
    ];

    environment.systemPackages = [ cfg.package ];

    # Generate the configuration file
    home-manager.users.${config.user.name} = {
      xdg.configFile."hyprpanel/config.json" = {
        text = builtins.toJSON cfg.settings;
      };
    };

    # Systemd user service for auto-starting with Hyprland
    systemd.user.services.hyprpanel = mkIf cfg.systemd.enable {
      description = "Hyprpanel - a status panel for Hyprland";
      wantedBy = [ "hyprland-session.target" ];
      partOf = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/hyprpanel";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}

