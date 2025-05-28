# users/alc/home-linux.nix
{
  config,
  pkgs,
  lib,
  username,
  inputs,
  ...
}:

with lib;

{
  imports = [
    ./common.nix # <--- Import the common configuration first

    # Linux-specific imports (Hyprland, Waybar, etc.)
    ../../modules/home-manager/programs/foot/default.nix
    ../../modules/home-manager/programs/hyprland/default.nix
    ../../modules/home-manager/programs/waybar/default.nix
    ../../modules/home-manager/programs/wofi/default.nix
    ../../modules/home-manager/programs/wlogout/default.nix
    ../../modules/home-manager/services/swww/default.nix
    ../../modules/home-manager/services/hypridle/default.nix
    ../../modules/home-manager/services/hyprlock/default.nix
  ];

  # ==================== Linux-Specific Options ====================
  # No need for home.username, home.homeDirectory, colorscheme, etc., as they are in common.nix
  # home.stateVersion is also in common.nix

  home.file.".config/wallpapers" = { # This is Linux-specific if you use it for Wayland
    source = ./wallpapers; # Relative to users/alc/
    recursive = true;
  };

  # Enable Linux-specific programs
  programs.foot.enable = true;
  programs.hyprland.managed.enable = true;
  programs.waybar.managed.enable = true;
  programs.wofi.managed.enable = true;
  programs.wlogout.managed.enable = true;
  services.swww.managed = {
    enable = true;
    systemd.enable = true;
  };
  services.hypridle.managed.enable = true;
  services.hyprlock.enable = true;
  services.hyprlock.wallpaper.useStandardDir = true;

  # Any other Linux-specific packages or configurations
  home.packages = with pkgs; [
    # swaylock # Example of a Linux-only package
  ];
}
