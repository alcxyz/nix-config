# modules/home-manager/desktop/hyprland/default.nix
{
  options,
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
with lib; # Ensure lib is in scope for lib.optionals

let
  cfg = config.desktop.hyprland;
  colorscheme = inputs.nix-colors.colorschemes.${builtins.toString config.desktop.colorscheme};
  colors = colorscheme.palette;
in
{
  options.desktop.hyprland = with types; {
    enable = mkEnableOption "Enable the Home Manager configuration for the Hyprland desktop environment suite.";

    waybar = { enable = mkEnableOption "Waybar configuration"; };
    swww = { enable = mkEnableOption "SWWW configuration"; };
    wofi = { enable = mkEnableOption "Wofi configuration"; };
    wlogout = { enable = mkEnableOption "wlogout configuration"; };
    hypridle = {
      enable = mkEnableOption "Hypridle configuration";
      settings = mkOption {
        type = types.attrs;
        default = {};
        description = "Settings for the Hypridle daemon. Specific options are defined in the hypridle submodule.";
      };
    };
    hyprlock = { 
      enable = mkEnableOption "hyprlock configuration"; 
    };
    # hyprpanel = { enable = mkEnableOption "hyprpanel configuration"; }; # Commented out
  };

  # Use lib.optionals to ensure `imports` is always a list
  imports = lib.optionals cfg.enable [
    ./waybar/default.nix
    ./swww/default.nix
    ./wofi/default.nix
    ./wlogout/default.nix
    ./hypridle/default.nix
    ./hyprlock/default.nix
    # ./hyprpanel/default.nix # Commented out
  ];

  config = mkIf cfg.enable {
    programs.hyprland = {
      enable = true;
      withUWSM = true;
      xwayland.enable = true;
    };

    environment.sessionVariables.NIXOS_OZONE_WL = "1";

    home.configFile = {
      "hypr/launch".source = ./launch;
      "hypr/hyprland.conf".source = ./hyprland.conf;
      "hypr/colors.conf" = {
        text = ''
          general {
            col.active_border = 0xff${colors.base0C} 0xff${colors.base0D} 270deg
            col.inactive_border = 0xff${colors.base00}
          }
        '';
      };
    };

    desktop.hyprland = {
      waybar.enable = true;
      swww.enable = true;
      wofi.enable = true;
      wlogout.enable = true;
      hypridle.enable = true; 
      hyprlock.enable = true;
    };
  };
}
