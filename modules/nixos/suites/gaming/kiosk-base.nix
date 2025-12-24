# modules/nixos/suites/gaming/kiosk-base.nix
{ config, lib, pkgs, ... }: {
  config = lib.mkIf config.suites.gaming.enable {
    systemd.services.gaming-kiosk = {
      description = "Isolated Steam Kiosk";
      after = [ "systemd-logind.service" "network.target" ];
      requires = [ "systemd-logind.service" ];
      
      serviceConfig = {
        User = "alc";
        Group = "users";
        SupplementaryGroups = [ "video" "render" "input" ];

        PAMName = "gaming-kiosk";
        
        Environment = [
          "XDG_SEAT=seat-gaming"
          "XDG_SESSION_TYPE=wayland"
          "XDG_SESSION_CLASS=user"
          "WLR_LIBINPUT_NO_DEVICES=1"
          "XDG_RUNTIME_DIR=/run/user/%U"
          "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%U/bus"
          "PULSE_SERVER=unix:/run/user/%U/pulse/native"

          "WLR_DRM_DEVICES=/dev/dri/by-path/pci-0000:01:00.0-card"
          "VK_ICD_FILENAMES=/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.x86_64.json"
          "LIBVA_DRIVER_NAME=nvidia"
          "__GLX_VENDOR_LIBRARY_NAME=nvidia"
          "GBM_BACKEND=nvidia-drm"
          
          "LIBSEAT_BACKEND=logind"
        ];
        
        # Hardware access permissions
        #Capabilities = "CAP_SYS_ADMIN+ep CAP_SYS_NICE+ep";
        #AmbientCapabilities = [ "CAP_SYS_ADMIN" "CAP_SYS_NICE" ];

        ExecStart = ''
          ${pkgs.gamescope}/bin/gamescope \
            --backend drm \
            --prefer-vk-device 10de:1b80 \
            -O HDMI-A-3 \
            -W 2560 -H 1440 -r 120 \
            --xwayland-count 1 \
            -- ${pkgs.vulkan-tools}/bin/vkcube
        '';
        Restart = "on-failure";
        RestartSec = 5;
      };
      wantedBy = [ "multi-user.target" ];
    };

    systemd.services.gaming-kiosk.serviceConfig.LimitCORE = "infinity";

  };
}
