{ options, config, lib, pkgs, ... }:
with lib;
{
  options.hardware.bluetooth = with types; {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable system-wide bluetooth services and hardware configuration.";
    };
  };

  config = mkIf config.hardware.bluetooth.enable {
    services.blueman.enable = true;

    hardware.bluetooth = {
      enable = true;
      settings = {
        General = {
          FastConnectable = true;
          JustWorksRepairing = "always";
          Privacy = "device";
        };
        Policy = with pkgs; {
          AutoEnable = true;
        };
      };
    };
  };
}
