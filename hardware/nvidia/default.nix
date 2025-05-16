{ options
, config
, lib
, ...
}:
with lib;
with lib.custom; let
  cfg = config.hardware.nvidia;
in
{
  options.hardware.nvidia = with types; {
    enable = mkBoolOpt false "Enable drivers and patches for Nvidia hardware.";
  };

  config = mkIf cfg.enable {
    services.xserver.videoDrivers = [ "nvidia" ];
    hardware.nvidia = {
      modesetting.enable = true;
      open = false;
      nvidiaSettings = true;
      package = config.boot.kernelPackages.nvidiaPackages.production; 
    };

    # Enable OpenGL and hardware acceleration.
    hardware.graphics.enable = true;
    #hardware.opengl.driSupport = true;
    #hardware.opengl.driSupport32Bit = true;

    environment.variables = {
      CUDA_CACHE_PATH = "$XDG_CACHE_HOME/nv";
    };
    environment.shellAliases = { nvidia-settings = "nvidia-settings --config='$XDG_CONFIG_HOME'/nvidia/settings"; };

    # Hyprland settings
    environment.sessionVariables.WLR_NO_HARDWARE_CURSORS = "1"; # Fix cursor rendering issue on wlr nvidia.
  };
}
