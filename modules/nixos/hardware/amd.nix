# nix-config/modules/nixos/hardware/amd.nix
{ options, config, lib, pkgs, ... }:

with lib;
let cfg = config.hardware.amd; in
{
  options.hardware.amd.enable = mkEnableOption "AMD iGPU Support";

  config = mkIf cfg.enable {
    boot.initrd.kernelModules = [ "amdgpu" ];
    services.xserver.videoDrivers = [ "amdgpu" ];

    hardware.graphics = {
      enable = true;
      enable32Bit = true;
      extraPackages = with pkgs; [
        libva
        libva-utils
        rocmPackages.clr.icd
        libva-vdpau-driver 
        libvdpau-va-gl
      ];
    };

    environment.systemPackages = with pkgs; [
      amdgpu_top
      mesa-demos # Fixed: renamed from glxinfo
      vulkan-tools
    ];

    environment.sessionVariables = {
      LIBVA_DRIVER_NAME = "radeonsi";
    };
  };
}
