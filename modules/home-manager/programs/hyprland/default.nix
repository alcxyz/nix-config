# modules/home-manager/programs/hyprland/default.nix
{ options, config, lib, pkgs, inputs, ... }:
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
    # NOTE: we NO LONGER manage wayland.windowManager.hyprland here.
    # NixOS handles Hyprland itself.

    home.pointerCursor = {
      gtk.enable = true;
      enable = true;
      package = pkgs.adwaita-icon-theme;
      name = "Adwaita";
      size = 24;
    };

    gtk = {
      enable = true;
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

    # Keep colors.conf generated from nix-colors
    xdg.configFile."hypr/colors.conf".text = ''
      general {
        col.active_border = 0xff${colors.base0C} 0xff${colors.base0D} 270deg
        col.inactive_border = 0xff${colors.base00}
      }
    '';

    # IMPORTANT: do NOT manage hyprland.conf here anymore.
    # Remove this:
    # xdg.configFile."hypr/hyprland.conf".source = ./hyprland.conf;
  };
}
