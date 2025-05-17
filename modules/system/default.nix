{ options, config, lib, pkgs, ... }:
with lib;
let
  cfg = config.system;
in
{
  options.system = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the base system configurations.";
    };
  };

  # Conditionally import sub-modules
  imports = lib.optionals cfg.enable [
    ./packages/default.nix
    ./hardware/bluetooth.nix
    ./hardware/audio.nix
    ./fonts/default.nix
    ./env/default.nix
    ./nix/default.nix
    ./services/ssh/default.nix
  ];

  config = mkIf cfg.enable { # Apply mkIf here to the configuration attributes
    # Enable hardware components
    hardware.bluetooth.enable = true;
    hardware.audio.enable = true;

    # Enable core system features
    system.nix.enable = true;
    system.fonts.enable = true;
    services.ssh.enable = true;

    # The environment module is imported, its default configurations will apply.
    # The custom system.env option is now available for use in host configs.
  };
}