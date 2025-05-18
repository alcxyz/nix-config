# modules/home-manager/desktop/default.nix
{
  options, config, lib, pkgs, inputs, ...
}:
with lib;

let
  # cfg = config.desktop; # We'll use config.desktop directly for clarity now
  inherit (inputs.nix-colors.lib-contrib {inherit pkgs;}) gtkThemeFromScheme;
in
{
  options.desktop = with types; {
    # General desktop options
    colorscheme = mkOption {
      type = str;
      default = "catppuccin-mocha"; # Your existing default
      description = "Overall colorscheme for the desktop environment.";
    };

    # Hyprland suite components options
    hyprland = {
      enable = mkEnableOption "Core Hyprland window manager";
      # If hyprland itself has specific settings beyond its config files, define them here
      # settings = mkOption { type = types.attrs; default = {}; }; 
    };
    waybar = { enable = mkEnableOption "Waybar status bar"; };
    swww = { enable = mkEnableOption "SWWW wallpaper daemon"; };
    wofi = { enable = mkEnableOption "Wofi application launcher"; };
    wlogout = { enable = mkEnableOption "wlogout session exit UI"; };
    hypridle = {
      enable = mkEnableOption "hypridle idle daemon";
      settings = mkOption { # Placeholder for settings defined in hypridle's own module
        type = types.attrs; 
        default = {}; 
        description = "Settings for hypridle, defined in its submodule.";
      };
    };
    hyprlock = {
      enable = mkEnableOption "hyprlock screen locker";
      settings = mkOption { # Placeholder for settings defined in hyprlock's own module
        type = types.attrs; 
        default = {}; 
        description = "Settings for hyprlock, defined in its submodule.";
      };
    };
    # hyprpanel option could be added here if you decide to re-integrate it
  };

  imports = [
    # These paths assume that 'hyprland' is a directory at the same level as 'desktop'
    # e.g., modules/home-manager/hyprland/default.nix
    ../hyprland/default.nix  # This will be refactored to ONLY handle hyprland itself

    # Hyprland addon modules, assuming they are in subdirectories of the hyprland directory
    ../hyprland/waybar/default.nix
    ../hyprland/swww/default.nix
    ../hyprland/wofi/default.nix
    ../hyprland/wlogout/default.nix
    ../hyprland/hypridle/default.nix
    ../hyprland/hyprlock/default.nix
    # ../hyprland/hyprpanel/default.nix # If used
  ];

  config = {
    # Assuming prism is a Home Manager option (adjust if it's NixOS specific)
    # prism = {
    #   enable = true;
    #   wallpapers = ./wallpapers; # Path is now relative to this file (modules/home-manager/desktop/)
    #   colorscheme = inputs.nix-colors.colorschemes.${cfg.colorscheme};
    # };

    # GTK theme setting - note that gtkThemeFromScheme is used below for a HM-managed theme
    # This environment variable might be redundant or conflict depending on setup.
    # Consider removing this if home.extraOptions.gtk handles it fully.
    # environment.variables = {
    #   GTK_THEME = "Catppuccin-Mocha-Compact-Blue-dark"; # Original value, consider deriving from colorscheme
    # };


    # Default GTK and other general desktop settings
    home.extraOptions.gtk = {
      enable = true;
      theme = {
        name = inputs.nix-colors.colorschemes.${config.desktop.colorscheme}.slug;
        package = gtkThemeFromScheme {scheme = inputs.nix-colors.colorschemes.${config.desktop.colorscheme};};
      };
      iconTheme = {
        name = "Papirus-Dark";
        package = pkgs.papirus-icon-theme;
      };
    };

    # Default enable states for Hyprland suite components
    # These are set here in the orchestrating module.
    # Users can override these in their home.nix if they want to disable a component.
    desktop = {
      hyprland.enable = true; # Enable Hyprland core by default if desktop is used
      waybar.enable = true;
      swww.enable = true;
      wofi.enable = true;
      wlogout.enable = true;
      hypridle.enable = true;
      # hypridle.settings = { lockTimeout = 300; dpmsTimeout = 600; }; # Example overrides
      hyprlock.enable = true;
      # hyprlock.settings = { wallpaper.path = "..."; }; # Example overrides
    };
  };
}
