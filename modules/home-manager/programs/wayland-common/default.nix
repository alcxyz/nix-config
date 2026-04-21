# modules/home-manager/programs/wayland-common/default.nix
#
# Shared Wayland compositor settings: cursor theme, GTK config, and
# environment variables needed by both Hyprland and Niri sessions.
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.wayland-common;
in {
  options.programs.wayland-common = {
    enable = lib.mkEnableOption "Shared Wayland compositor settings (cursor, GTK, env)";
  };

  config = lib.mkIf cfg.enable {

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

  };
}
