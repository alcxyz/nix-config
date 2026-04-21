# modules/home-manager/programs/niri/default.nix
#
# Manages Niri-related user files: config symlink, helper scripts,
# and enables the shared Wayland settings (cursor, GTK, env).
{ config, lib, pkgs, username, ... }:

let
  cfg = config.programs.niri.managed;
in {
  options.programs.niri.managed = {
    enable = lib.mkEnableOption "Manage Niri-related user files (config, scripts)";
  };

  config = lib.mkIf cfg.enable {

    # Shared wayland settings (cursor, GTK, ozone)
    programs.wayland-common.enable = true;

    # Symlink niri config for live editing
    xdg.configFile."niri/config.kdl".source = config.lib.file.mkOutOfStoreSymlink
      "${config.home.homeDirectory}/nix/nix-config/users/${username}/configs/niri/config.kdl";

    # Niri-specific scripts
    home.file.".config/niri/scripts/fkey-handler.sh" = {
      source = ./scripts/fkey-handler.sh;
      executable = true;
    };

    home.file.".config/niri/scripts/scratch-toggle.sh" = {
      source = ./scripts/scratch-toggle.sh;
      executable = true;
    };

  };
}
