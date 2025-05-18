{
  options,
  config,
  lib,
  pkgs, # Added pkgs to function arguments
  # inputs, # hyprpanel might require this, will see if pkgs.hyprpanel works
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

  # Removed: imports = if config.suites.hyprland.enable then [ ./packages.nix ] else [ ];

  config = mkIf config.suites.hyprland.enable {
    # Packages from the former packages.nix are now here:
    environment.systemPackages = with pkgs; [
      hyprland
      waybar
      swww
      wofi
      wlogout
      hypridle
      hyprlock
      #hyprpanel # Assuming this is available in pkgs, possibly via an overlay from the input
      swaynotificationcenter
      libnotify
      # Add any other essential packages like hyprctl if not a dependency of hyprland
      # hyprctl # included with hyprland package
    ];

    # Any other top-level Hyprland system configurations can go here.
    # For example:
    # services.xserver.displayManager.sddm.enable = true; # Ensure this is suitable for Hyprland
    # services.xserver.windowManager.hyprland.enable = true; # If there's such an option
  };
}
