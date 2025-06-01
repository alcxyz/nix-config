{ options
, config
, lib
, pkgs
, ...
}:
with lib;
let
  cfg = config.hardware.nvidia;
in
{
  options.hardware.nvidia.enable = mkOption {
    type = types.bool;
    default = false;
    description = "Enable drivers and patches for Nvidia hardware.";
  };

  config = mkIf cfg.enable {
    services.xserver.videoDrivers = [ "nvidia" ];
    
    hardware.nvidia = {
      modesetting.enable = true;
      open = false;
      nvidiaSettings = true;
      package = config.boot.kernelPackages.nvidiaPackages.production;
      powerManagement.enable = true;
      powerManagement.finegrained = false;
    };

    # Enable OpenGL and hardware acceleration with better Vulkan support
    hardware.graphics = {
      enable = true;
      enable32Bit = true;
      extraPackages = with pkgs; [
        vulkan-tools
        vulkan-headers
        vulkan-loader
        vulkan-validation-layers
        libva
        libva-utils
        egl-wayland
        glxinfo
        SDL2
        wayland
        wayland-protocols
        wayland-utils
        wayland-scanner
        # Fix libdecor warnings
        libdecor
        gtk3
        cairo
        # Also add these Wayland decoration packages
        wayland-protocols
        xdg-desktop-portal
        xdg-desktop-portal-wlr
        # Lutris specific
        nvidia-vaapi-driver
      ];
      extraPackages32 = with pkgs.pkgsi686Linux; [
        vulkan-loader
        vulkan-validation-layers
        nvidia-vaapi-driver
      ];
    };

    # Boot-time configuration for NVIDIA
    boot.kernelParams = [
      "nvidia-drm.modeset=1"
      "nvidia-drm.fbdev=1"
    ];

    environment.variables = {
      CUDA_CACHE_PATH = "$XDG_CACHE_HOME/nv";
      GBM_BACKEND = "nvidia-drm";
      __GLX_VENDOR_LIBRARY_NAME = "nvidia";
      # Fixed: Use the correct architecture-specific filename
      VK_DRIVER_FILES = "/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.x86_64.json:/run/opengl-driver-32/share/vulkan/icd.d/nvidia_icd.i686.json";
      VK_ICD_FILENAMES = "/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.x86_64.json:/run/opengl-driver-32/share/vulkan/icd.d/nvidia_icd.i686.json";
      VK_LAYER_PATH = "/run/opengl-driver/share/vulkan/explicit_layer.d:/run/opengl-driver-32/share/vulkan/explicit_layer.d";
      # Wayland
      LIBVA_DRIVER_NAME = "nvidia";
      XDG_SESSION_TYPE = "wayland";
      # EGL
      __EGL_VENDOR_LIBRARY_FILENAMES = "/run/opengl-driver/share/glvnd/egl_vendor.d/10_nvidia.json";
    };

    environment.sessionVariables = {
      WLR_NO_HARDWARE_CURSORS = "1";
      NIXOS_OZONE_WL = "1";
      MOZ_ENABLE_WAYLAND = "1";
      # Additional Wayland variables
      QT_QPA_PLATFORM = "wayland;xcb";
      SDL_VIDEODRIVER = "wayland";
      _JAVA_AWT_WM_NONREPARENTING = "1";
    };

    environment.systemPackages = with pkgs; [
      vulkan-tools
      vulkan-headers
      libva
      libva-utils
      egl-wayland
      glxinfo
    ];
  };
}
