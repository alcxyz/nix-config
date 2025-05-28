{
  options,
  config,
  lib,
  pkgs,
  ...
}:
with lib;
{
  options.suites.hyprland = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the Hyprland system suite configurations.";
    };
  };

  config = mkIf config.suites.hyprland.enable {

    programs.hyprland = {
      enable = true;
      withUWSM = true;
      xwayland.enable = true;
    };

    # Packages from the former packages.nix are now here:
    environment.systemPackages = with pkgs; [
      waybar
      swww
      wofi
      wlogout
      hypridle
      hyprlock
      #hyprpanel # Assuming this is available in pkgs, possibly via an overlay from the input
      swaynotificationcenter
      libnotify

      grim
      slurp
      swappy
      imagemagick

      (writeShellScriptBin "screenshot" ''
        grim -g "$(slurp)" - | convert - -shave 1x1 PNG:- | wl-copy
      '')
      (writeShellScriptBin "screenshot-edit" ''
        wl-paste | swappy -f -
      '')
    ];

    # Any other top-level Hyprland system configurations can go here.
    # For example:
    # services.xserver.displayManager.sddm.enable = true; # Ensure this is suitable for Hyprland
    # services.xserver.windowManager.hyprland.enable = true; # If there's such an option
  };
}
