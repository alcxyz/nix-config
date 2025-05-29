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

  # You might want to add other options under hardware.nvidia if needed, e.g.:
  # options.hardware.nvidia.open = mkOption { type = types.bool; default = false; };
  # options.hardware.nvidia.nvidiaSettings = mkOption { type = types.bool; default = true; };
  # options.hardware.nvidia.package = mkOption { type = types.package; /* default based on kernel */ };

  config = mkIf cfg.enable {
    services.xserver.videoDrivers = [ "nvidia" ];
    hardware.nvidia = {
      modesetting.enable = true;
      open = false;
      nvidiaSettings = true;
      # Ensure pkgs is available if you access config.boot.kernelPackages
      package = config.boot.kernelPackages.nvidiaPackages.stable;
    };

    # Enable OpenGL and hardware acceleration.
    hardware.graphics.enable = true;
    hardware.graphics.enable32Bit = true;

    environment.variables = {
      CUDA_CACHE_PATH = "$XDG_CACHE_HOME/nv";
      GBM_BACKEND = "nvidia-drm";
      __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    };
    environment.shellAliases = { nvidia-settings = "nvidia-settings --config='$XDG_CONFIG_HOME'/nvidia/settings"; };

    # Hyprland settings
    environment.sessionVariables.WLR_NO_HARDWARE_CURSORS = "1"; # Fix cursor rendering issue on wlr nvidia.
  };
}
