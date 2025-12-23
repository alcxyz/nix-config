# modules/nixos/suites/gaming/kiosk-base.nix
{ config, lib, pkgs, ... }: {
  config = lib.mkIf config.suites.gaming.enable {
    systemd.services.gaming-kiosk = {
      description = "Isolated Steam Kiosk (NVIDIA via seatd)";
      after = [ "seatd.service" "network.target" ];
      requires = [ "seatd.service" ];
      
      serviceConfig = {
        User = "alc";
        Group = "users";
        # We MUST add seat here so the process can talk to /run/seatd.sock
        SupplementaryGroups = [ "seat" "video" "render" "input" ];
        
        Environment = [
          "XDG_SEAT=seat-gaming"
          "XDG_RUNTIME_DIR=/run/user/1000"
          "WLR_DRM_DEVICES=/dev/dri/by-path/pci-0000:01:00.0-card"
          "VK_ICD_FILENAMES=/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json"
          "LD_LIBRARY_PATH=/run/opengl-driver/lib:/run/opengl-driver-32/lib"
          "LIBVA_DRIVER_NAME=nvidia"
          "__GLX_VENDOR_LIBRARY_NAME=nvidia"
          "GBM_BACKEND=nvidia-drm"
          
          # This tells Gamescope/Libseat to use seatd instead of logind
          "LIBSEAT_BACKEND=seatd"
        ];
        
        # Hardware access permissions
        Capabilities = "CAP_SYS_ADMIN+ep CAP_SYS_NICE+ep";
        AmbientCapabilities = [ "CAP_SYS_ADMIN" "CAP_SYS_NICE" ];

        ExecStart = ''
          ${pkgs.gamescope}/bin/gamescope \
            --backend drm \
            --prefer-vk-device 10de:1b80 \
            -O HDMI-A-3 \
            -W 2560 -H 1440 -r 120 \
            --xwayland-count 1 \
            -- ${pkgs.flatpak}/bin/flatpak run com.valvesoftware.Steam
        '';
        Restart = "always";
        RestartSec = 5;
      };
      wantedBy = [ "multi-user.target" ];
    };
  };
}
