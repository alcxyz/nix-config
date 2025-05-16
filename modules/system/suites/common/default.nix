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
  ];

  # Note: Home Manager configurations (like environment variables) need to be handled separately
  # and imported in the user's home.nix.
}
