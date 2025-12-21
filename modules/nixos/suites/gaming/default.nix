# nix-config/modules/nixos/suites/gaming/default.nix
{ config, lib, pkgs, ... }: {
  imports = [ ./sunshine.nix ];

  options.suites.gaming.enable = lib.mkEnableOption "Gaming Infrastructure";

  config = lib.mkIf config.suites.gaming.enable {
    # Handles all Steam-supported controllers (Xbox, Sony, Nintendo, etc.)
    # This is essential for Steam Flatpak.
    hardware.steam-hardware.enable = true;
    
    boot.kernelModules = [ "nvidia_uvm" "uinput" ];

    # Steam Stream Ports
    networking.firewall = {
      allowedTCPPorts = [ 27036 ];
      allowedUDPPortRanges = [ { from=27031; to=27036; } ];
    };

    services.udev.extraRules = ''
      # 1. Sunshine/uinput
      KERNEL=="uinput", SUBSYSTEM=="misc", OPTIONS+="static_node=uinput", TAG+="uaccess"

      # 2. NVIDIA UVM (Critical for CUDA/NVENC)
      KERNEL=="nvidia_uvm", MODE="0666"

      # 3. General Controller Nodes
      KERNEL=="event*", GROUP="input", MODE="0660", TAG+="uaccess"
      KERNEL=="js*", GROUP="input", MODE="0664", TAG+="uaccess"

      # 4. Sony DualSense (DS5) specific
      KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0ce6", MODE="0660", TAG+="uaccess"
      KERNEL=="hidraw*", ATTRS{idVendor}=="054c", ATTRS{idProduct}=="0df2", MODE="0660", TAG+="uaccess"
    '';

  };
}
