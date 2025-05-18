{
  options,
  config,
  lib,
  ...
}:
with lib;
let
  cfg = config.suites.hyprland;
in
{
  options.suites.hyprland = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the Hyprland system suite configurations.";
    };
  };

  imports = [ (mkIf cfg.enable [
    ./packages.nix
    # Add other system-level configurations for Hyprland here if needed (e.g., services)
  ]) ];

  config =
    if cfg.enable then { # Changed to if/else for the config attribute value
      # Any top-level Hyprland system configurations can go here.
    } else {}; # Return an empty set if the suite is not enabled
}
