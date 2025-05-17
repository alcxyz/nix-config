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

  imports = mkIf cfg.enable [
    ./packages.nix
    # Add other system-level configurations for Hyprland here if needed (e.g., services)
  ];

  config = mkIf cfg.enable {
    # Any top-level Hyprland system configurations can go here.
  };
}