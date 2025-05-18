# modules/home-manager/programs/hyprland/default.nix
{
  options, config, lib, pkgs, inputs, ...
}:
with lib;

let
  cfg = config.programs.hyprland; # Use the module's own enable option
  activeColorscheme = inputs.nix-colors.colorschemes.${builtins.toString config.desktop.colorscheme}; # Access shared colorscheme
  colors = activeColorscheme.palette;
in
{
  options.programs.hyprland = {
    enable = mkEnableOption "Hyprland window manager";
    # Add any other hyprland-specific options here if needed in the future
    # package = mkOption { type = types.package; default = pkgs.hyprland; };
  };

  config = mkIf cfg.enable {
    programs.hyprland = {
      enable = true; # This enables the core HM program option for hyprland
      # package = cfg.package; # If you define a package option above
      withUWSM = true; 
      xwayland.enable = true;
    };

    environment.sessionVariables.NIXOS_OZONE_WL = "1";

    home.configFile = {
      "hypr/launch".source = ./launch;
      "hypr/hyprland.conf".source = ./hyprland.conf;
      "hypr/colors.conf" = { 
        text = '''
          general {
            col.active_border = 0xff${colors.base0C} 0xff${colors.base0D} 270deg
            col.inactive_border = 0xff${colors.base00}
            # Add other color-related settings for hyprland.conf itself here
          }
        ''';
      };
    };
  };
}
