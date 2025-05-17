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

  imports = lib.optionals cfg.enable [
    ./packages/default.nix
    ./hardware/bluetooth.nix
    ./hardware/audio.nix
    ./fonts/default.nix
    ./env/default.nix
    ./nix/default.nix
    ./services/ssh/default.nix
  ];

  config = { # Removed mkIf cfg.enable
    # Enable hardware components
    hardware.bluetooth.enable = cfg.enable; # Added cfg.enable conditional
    hardware.audio.enable = cfg.enable; # Added cfg.enable conditional

    # Enable core system features
    system.nix.enable = cfg.enable; # Added cfg.enable conditional
    system.fonts.enable = cfg.enable; # Added cfg.enable conditional
    services.ssh.enable = cfg.enable; # Added cfg.enable conditional

    # The environment module is imported, its default configurations will apply.
    # The custom system.env option is now available for use in host configs.
  };
}