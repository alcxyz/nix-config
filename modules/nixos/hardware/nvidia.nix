# nix-config/modules/nixos/hardware/nvidia.nix
{ options, config, lib, pkgs, ... }:

with lib;
let cfg = config.hardware.nvidia; in
{
  options.hardware.nvidia.enable = mkEnableOption "Nvidia Hardware Support";

  config = mkIf cfg.enable {
    services.xserver.videoDrivers = [ "nvidia" ];
    
    hardware.nvidia = {
      modesetting.enable = true;
      open = false;
      nvidiaSettings = true;
      package = config.boot.kernelPackages.nvidiaPackages.legacy_580;
    };

    hardware.graphics = {
      enable = true;
      enable32Bit = true;
      extraPackages = with pkgs; [ libva-utils egl-wayland nvidia-vaapi-driver ];
    };

    boot.kernelParams = [ "nvidia-drm.modeset=1" "nvidia-drm.fbdev=1" ];

    environment.variables = {
      #GBM_BACKEND = "nvidia-drm";
      #__GLX_VENDOR_LIBRARY_NAME = "nvidia";
    };
  };
}
