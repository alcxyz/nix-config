{ options, config, lib, pkgs, ... }:

with lib;

let
  cfg = config.hardware.nvidia;
in
{
  options.hardware.nvidia.enable = mkOption {
    type = types.bool;
    default = false;
    description = "Enable NVIDIA driver and GPU acceleration.";
  };

  config = mkIf cfg.enable {
    # Use the proprietary NVIDIA driver for Xorg / Wayland
    services.xserver.videoDrivers = [ "nvidia" ];

    hardware.nvidia = {
      modesetting.enable = true;
      open = false; # proprietary driver (better for gaming)
      nvidiaSettings = true;
      package = config.boot.kernelPackages.nvidiaPackages.production;

      powerManagement.enable = true;
      powerManagement.finegrained = false;
    };

    # OpenGL / Vulkan and 32‑bit support for Proton/Wine
    hardware.graphics = {
      enable = true;
      enable32Bit = true;

      extraPackages = with pkgs; [
        vulkan-tools
        libva
        libva-utils
        egl-wayland
        mesa-demos
      ];

      extraPackages32 = with pkgs.pkgsi686Linux; [
        vulkan-loader
      ];
    };

    # Basic kernel param needed for modesetting
    boot.kernelParams = [
      "nvidia-drm.modeset=1"
    ];

    # Safe, minimal env tweaks
    environment.variables = {
      # Harmless CUDA cache location; does NOT require global cudaSupport
      CUDA_CACHE_PATH = "$XDG_CACHE_HOME/nv";
    };

    # Session-level hints for Wayland apps
    environment.sessionVariables = {
      NIXOS_OZONE_WL = "1";        # Prefer Wayland for Electron/Chromium
      MOZ_ENABLE_WAYLAND = "1";    # Firefox on Wayland
      QT_QPA_PLATFORM = "wayland;xcb";
    };

    # Handy tools
    environment.systemPackages = with pkgs; [
      vulkan-tools
      libva-utils
      egl-wayland
    ];
  };
}
