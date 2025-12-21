# nix-config/modules/nixos/suites/gaming/default.nix
{ config, lib, pkgs, ... }: {
  options.suites.gaming.enable = lib.mkEnableOption "Gaming Infrastructure";

  config = lib.mkIf config.suites.gaming.enable {
    # Official Sunshine Service
    services.sunshine = {
      enable = true;
      autoStart = true;
      capSysAdmin = true; # Replaces manual security.wrappers logic
      openFirewall = true;
    };

    # Hardware & Input
    hardware.steam-hardware.enable = true;
    hardware.nvidia.modesetting.enable = true;
    boot.kernelModules = [ "uinput" "nvidia_uvm" ];

    services.udev.extraRules = ''
      KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess"
      KERNEL=="nvidia_uvm", MODE="0666"
      KERNEL=="event*", GROUP="input", MODE="0660", TAG+="uaccess"
    '';
    
    # Steam-specific firewall (Sunshine ports are handled by the service)
    networking.firewall = {
      allowedTCPPorts = [ 27036 ];
      allowedUDPPortRanges = [ { from = 27031; to = 27036; } ];
    };
  };
}
