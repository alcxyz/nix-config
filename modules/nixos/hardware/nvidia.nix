{ options
, config
, lib,
  pkgs # Added pkgs for config.boot.kernelPackages
, ...
}:
with lib;
let
  cfg = config.hardware.nvidia; # cfg now refers to the attrset hardware.nvidia
in
{
  options.hardware.nvidia.enable = mkOption { # Corrected: .enable is added here
    type = types.bool;
    default = false;
    description = "Enable drivers and patches for Nvidia hardware.";
  };

  # You might want to add other options under hardware.nvidia if needed, e.g.:
  # options.hardware.nvidia.open = mkOption { type = types.bool; default = false; };
  # options.hardware.nvidia.nvidiaSettings = mkOption { type = types.bool; default = true; };
  # options.hardware.nvidia.package = mkOption { type = types.package; /* default based on kernel */ };

  config = mkIf cfg.enable { # cfg.enable now correctly refers to options.hardware.nvidia.enable
    services.xserver.videoDrivers = [ "nvidia" ];
    hardware.nvidia = {
      modesetting.enable = true;
      open = false; # Consider making this configurable via an option if needed
      nvidiaSettings = true; # Consider making this configurable
      # Ensure pkgs is available if you access config.boot.kernelPackages
      package = config.boot.kernelPackages.nvidiaPackages.production;
    };

    # Enable OpenGL and hardware acceleration.
    hardware.graphics.enable = true;
    #hardware.opengl.driSupport = true; # These are often implicitly handled or part of graphics.enable
    #hardware.opengl.driSupport32Bit = true;

    environment.variables = {
      CUDA_CACHE_PATH = "$XDG_CACHE_HOME/nv";
    };
    environment.shellAliases = { nvidia-settings = "nvidia-settings --config='$XDG_CONFIG_HOME'/nvidia/settings"; };

    # Hyprland settings
    environment.sessionVariables.WLR_NO_HARDWARE_CURSORS = "1"; # Fix cursor rendering issue on wlr nvidia.
  };
}
