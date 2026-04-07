# modules/home-manager/programs/hyprland/default.nix
{ options, config, lib, pkgs, inputs, username, ... }:
with lib;

let
  cfg = config.programs.hyprland.managed;
  colorscheme = inputs.nix-colors.colorschemes.${config.colorscheme.name};
  colors = colorscheme.palette;
in {
  options.programs.hyprland.managed = {
    enable = mkEnableOption "Manage Hyprland-related user files (scripts, colors)";
  };

  config = mkIf cfg.enable {

    home.pointerCursor = {
      gtk.enable = true;
      enable = true;
      package = pkgs.adwaita-icon-theme;
      name = "Adwaita";
      size = 24;
    };

    gtk = {
      enable = true;
      gtk4.theme = null; # adopt new HM default (no gtk4 theme override)
      iconTheme = {
        name = "Papirus-Dark";
        package = pkgs.papirus-icon-theme;
      };
    };

    home.sessionVariables.NIXOS_OZONE_WL = "1";

    home.file.".config/hypr/scripts/fkey_handler.sh" = {
      source = ./scripts/fkey_handler.sh;
      executable = true;
    };

    # Symlink hyprland configs directly to the repo checkout so edits take
    # effect immediately without a home-manager rebuild.
    xdg.configFile."hypr/hyprland.conf".source = config.lib.file.mkOutOfStoreSymlink
      "${config.home.homeDirectory}/nix/nix-config/users/${username}/configs/hypr/hyprland.conf";
    xdg.configFile."hypr/binds.conf".source = config.lib.file.mkOutOfStoreSymlink
      "${config.home.homeDirectory}/nix/nix-config/users/${username}/configs/hypr/binds.conf";

    # Keep colors.conf generated from nix-colors
    xdg.configFile."hypr/colors.conf".text = ''
      general {
        col.active_border = 0xff${colors.base0C} 0xff${colors.base0D} 270deg
        col.inactive_border = 0xff${colors.base00}
      }
    '';

  };
}
