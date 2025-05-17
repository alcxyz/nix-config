{
  config,
  pkgs,
  lib,
  ...
}:
with lib;

{
  environment.systemPackages = with pkgs; [
    hyprland
    waybar
    swww
    wofi
    wlogout
    hypridle
    hyprlock
    hyprpanel
    swaynotificationcenter
    libnotify
    # Add any other essential packages like hyprctl if not a dependency of hyprland
    # It often is, but being explicit can help.
    # hyprctl # included with hyprland package
  ];
}
