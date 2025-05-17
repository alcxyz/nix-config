# modules/system/default.nix
{ options, config, lib, pkgs, username, ... }: # These args are supplied by nixosSystem

with lib;
let
  cfg = config.system; # Accesses the option defined below
in
{
  options.system = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the base system configurations.";
    };
  };

  # These imports are conditional on this module being enabled
  imports = mkIf cfg.enable [
    # Paths are relative to this file (modules/system/default.nix)
    ./packages/default.nix
    ./hardware/bluetooth.nix
    ./hardware/audio.nix # Your audio module
    ./fonts/default.nix
    ./env/default.nix
    ./nix/default.nix
    ./services/ssh/default.nix
    # Add other core system components here that are part of the "base"
  ];

  config = mkIf cfg.enable {
    # Configurations applied when system.enable = true;

    # Enable features from the imported modules above
    # These options should be defined within the respective imported modules
    # For example, if ./hardware/bluetooth.nix defines hardware.bluetooth.enable:
    hardware.bluetooth.enable = true;
    hardware.audio.enable = true; # Assuming ./hardware/audio.nix defines this

    # If ./nix/default.nix defines system.nix.enable (or similar):
    # system.nix.enable = true; # Example, adjust to actual option name

    # If ./fonts/default.nix defines system.fonts.enable:
    # system.fonts.enable = true; # Example

    # If ./services/ssh/default.nix defines services.openssh.enable (NixOS standard option):
    services.ssh.enable = true; # Example, assuming ssh module configures services.openssh

    # The environment module (./env/default.nix) is imported;
    # its configurations will apply if it defines them unconditionally or via its own options.
  };
}

