# modules/nixos/suites/gaming/kiosk-base.nix
{ config, lib, pkgs, username ? "alc", ... }:

let
  user = username;
  steamFlatpakId = "com.valvesoftware.Steam";
in
{
  config = lib.mkIf config.suites.gaming.enable {
    systemd.services.gaming-kiosk = {
      description = "Isolated Gamescope Kiosk (seat-gaming, NVIDIA DRM)";
      after = [ "systemd-logind.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      requires = [ "systemd-logind.service" ];
      wantedBy = [ "multi-user.target" ];

      # Avoid boot/login getting stuck in restart storms
      startLimitIntervalSec = 60;
      startLimitBurst = 5;

      serviceConfig = {
        User = user;
        Group = "users";
        SupplementaryGroups = [ "video" "render" "input" ];

        PAMName = "gaming-kiosk";

        # Let gamescope start without any local input devices on that seat
        Environment = [
          # Make Flatpak usable from a system unit
          "PATH=/run/current-system/sw/bin:${pkgs.coreutils}/bin:${pkgs.flatpak}/bin:${pkgs.bubblewrap}/bin"

          # Seat/session identity (logind multiseat)
          "XDG_SEAT=seat-gaming"
          "XDG_SESSION_TYPE=wayland"
          "XDG_SESSION_CLASS=user"
          "LIBSEAT_BACKEND=logind"

          # Runtime + bus (pam_systemd creates /run/user/%U)
          "XDG_RUNTIME_DIR=/run/user/%U"
          "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%U/bus"
          "PULSE_SERVER=unix:/run/user/%U/pulse/native"

          # No physical input yet (stream-only)
          "WLR_LIBINPUT_NO_DEVICES=1"

          # Pin everything to NVIDIA
          "WLR_DRM_DEVICES=/dev/dri/by-path/pci-0000:01:00.0-card"
          "VK_ICD_FILENAMES=/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.x86_64.json"
          "LIBVA_DRIVER_NAME=nvidia"
          "__GLX_VENDOR_LIBRARY_NAME=nvidia"
          "GBM_BACKEND=nvidia-drm"
        ];

        # Flatpak/bwrap strongly prefers a “normal unprivileged” context
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        NoNewPrivileges = true;
        RestrictNamespaces = false;

        LimitCORE = "infinity";

        Restart = "always";
        RestartSec = 2;

        ExecStart = ''
          ${pkgs.gamescope}/bin/gamescope \
            --backend drm \
            --prefer-vk-device 10de:1b80 \
            -O HDMI-A-3 \
            -W 2560 -H 1440 -r 120 \
            --xwayland-count 1 \
            -- ${pkgs.flatpak}/bin/flatpak run ${steamFlatpakId} -gamepadui
        '';
      };
    };
  };
}
