{ options, config, lib, pkgs, ... }:
with lib;
{
  # Removed options.hardware.bluetooth definition

  config = mkIf config.hardware.bluetooth.enable {
    services.blueman.enable = true;

    hardware.bluetooth = {
      # enable = true; # REMOVED: This was causing recursion.
      powerOnBoot = true;
      settings = {
        General = {
          FastConnectable = true;
          JustWorksRepairing = "always";
          Privacy = "device";
        };
        Policy = {
          AutoEnable = true;
        };
      };
    };
  };
}
