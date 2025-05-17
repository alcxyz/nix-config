{ options, config, lib, ... }:
with lib;
let
  cfg = config.suites.common;
in
{
  options.suites.common = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the common suite configurations.";
    };
  };

  imports = mkIf cfg.enable [
    ../../core/default.nix
    ../../packages/default.nix
    ../../hardware/bluetooth.nix
    ../../hardware/audio.nix
    ../../fonts/default.nix # Corrected import path for the fonts module
    ../../env/default.nix # Corrected import path for the environment module
    # Removed networking.nix - host specific
  ];

  config = mkIf cfg.enable {
    # Enable hardware components included in the common suite
    hardware.bluetooth.enable = true;
    hardware.audio.enable = true;
    # Removed networking.enable - host specific

    # Enable the fonts module
    system.fonts.enable = true;

    # The environment module is imported, its default configurations will apply.
    # The custom system.env option is now available for use in host configs.
  };

  # Note: Home Manager configurations (like environment variables) need to be handled separately
  # and imported in the user's home.nix.
}
