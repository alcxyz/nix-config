{ options
, config
, lib
, ...
}:
with lib;
with lib.custom; let
  cfg = config.hardware.networking;
in
{
  options.hardware.networking = with types; {
    enable = mkBoolOpt false "Enable pipewire";
  };

  config = mkIf cfg.enable {
    networking = {
      networkmanager.enable = true;
      hostId = "4e7ded69";
      bridges.br0.interfaces = [ "enp7s0" ];
      interfaces = {
        enp6s0 = {
          useDHCP = true;
        };
        enp7s0 = {
          useDHCP = false;
        };
        br0 = {
          useDHCP = false;
        };
      };
    };
  };
}
