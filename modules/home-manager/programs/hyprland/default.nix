# modules/home-manager/desktop/hyprland/default.nix
{
  options, config, lib, pkgs, inputs, ...
}:
with lib;

let
  # This module is now controlled by config.desktop.hyprland.enable,
  # which is set by the parent module (modules/home-manager/desktop/default.nix).
  hyprlandIsEnabled = config.desktop.hyprland.enable;

  # Standard way to access the colorscheme, assuming config.desktop.colorscheme is set by the parent.
  activeColorscheme = inputs.nix-colors.colorschemes.${builtins.toString config.desktop.colorscheme};
  colors = activeColorscheme.palette;
in
{
  # This module NO LONGER defines options for itself or its former submodules.
  # Those are now defined in modules/home-manager/desktop/default.nix.
  # It only provides the configuration for Hyprland itself.

  # No 'imports' for waybar, wofi, etc. here anymore.

  config = mkIf hyprlandIsEnabled {
    # Core Hyprland program setup
    programs.hyprland = {
      enable = true;
      withUWSM = true; 
      xwayland.enable = true;
    };

    # Session variables specific to Hyprland environment
    environment.sessionVariables.NIXOS_OZONE_WL = "1";

    # Hyprland config files
    home.configFile = {
      # Paths are relative to this file's location (modules/home-manager/desktop/hyprland/)
      "hypr/launch".source = ./launch;
      "hypr/hyprland.conf".source = ./hyprland.conf;
      "hypr/colors.conf" = { # Dynamically generated colors.conf
        text = '''
          general {
            col.active_border = 0xff${colors.base0C} 0xff${colors.base0D} 270deg
            col.inactive_border = 0xff${colors.base00}
            # Add other color-related settings for hyprland.conf itself here
          }
        ''';
      };
      # Any other files specific to Hyprland core configuration
    };

    # NO LONGER responsible for enabling waybar, wofi, etc.
    # That's handled by modules/home-manager/desktop/default.nix
  };
}
