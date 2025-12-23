# modules/nixos/suites/gaming/launchers.nix
{ pkgs, ... }:

let
  gamescopeKiosk = pkgs.writeShellScriptBin "gamescope-kiosk" ''
    # 1. Force NVIDIA for Rendering (The 'Math' part)
    export __GLX_VENDOR_LIBRARY_NAME=nvidia
    export VK_ICD_FILENAMES=/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json
    export GBM_BACKEND=nvidia-drm
    
    # 2. Direct output to our Master Kiosk (The 'Display' part)
    export WAYLAND_DISPLAY=wayland-gaming
    
    # 3. Optional: Ensure games see the 1440p target if they don't auto-detect
    export SDL_VIDEO_MIN_RESOLUTION=2560x1440
    
    exec "$@"
  '';
in {
  environment.systemPackages = [ gamescopeKiosk ];
}
