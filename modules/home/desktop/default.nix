{ options, config, lib, pkgs, inputs, ... }:

with lib;

let
  inherit (inputs.nix-colors.lib-contrib {inherit pkgs;}) gtkThemeFromScheme;
  cfg = config.desktop;
in
{
  options.desktop = with types; {
    colorscheme = mkOption {
      type = str;
      default = "catppuccin-mocha";
      description = "Theme to use for the desktop";
    };
    # autoLogin was a NixOS option, not Home Manager, so it's not included here.
  };

  config = {
    # Assuming prism is a Home Manager option (adjust if it's NixOS specific)
    prism = {
      enable = true;
      wallpapers = ./wallpapers; # Path is now relative to this file (modules/home/desktop/)
      colorscheme = inputs.nix-colors.colorschemes.${cfg.colorscheme};
    };

    # GTK theme setting - note that gtkThemeFromScheme is used below for a HM-managed theme
    # This environment variable might be redundant or conflict depending on setup.
    # Consider removing this if home.extraOptions.gtk handles it fully.
    # environment.variables = {
    #   GTK_THEME = "Catppuccin-Mocha-Compact-Blue-dark"; # Original value, consider deriving from colorscheme
    # };

    home.extraOptions.gtk = {
      enable = true;
      theme = {
        name = inputs.nix-colors.colorschemes.${cfg.colorscheme}.slug;
        package = gtkThemeFromScheme {scheme = inputs.nix-colors.colorschemes.${cfg.colorscheme};};
      };
      iconTheme = {
        name = "Papirus-Dark";
        package = pkgs.papirus-icon-theme;
      };
    };

    # No NixOS service configurations belong in a Home Manager module.
    # services.xserver.displayManager.autoLogin = ...; was removed.
  };
}