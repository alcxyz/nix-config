# modules/nixos/suites/gaming/kiosk-base.nix
{ config, lib, pkgs, username ? "alc", ... }:

let
  user = username;

  steamLoop = pkgs.writeShellScript "steam-kiosk-loop" ''
    set -euo pipefail

    export PATH="/run/current-system/sw/bin:${pkgs.coreutils}/bin:${pkgs.flatpak}/bin:${pkgs.bubblewrap}/bin"

    # Wait until gamescope has created its Wayland socket
    sock="$XDG_RUNTIME_DIR/gamescope-0"
    for _ in $(seq 1 200); do
      [ -S "$sock" ] && break
      sleep 0.05
    done

    while true; do
      ${pkgs.flatpak}/bin/flatpak run \
        --env=WAYLAND_DISPLAY=gamescope-0 \
        --env=PIPEWIRE_REMOTE=pipewire-0 \
        com.valvesoftware.Steam -gamepadui || true
      sleep 2
    done
  '';

in
{
  config = lib.mkIf config.suites.gaming.enable {
    systemd.services.gaming-kiosk = {
      description = "Isolated Gamescope Kiosk (seat-gaming, NVIDIA DRM)";
      after = [ "systemd-logind.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      requires = [ "systemd-logind.service" ];
      wantedBy = [ "multi-user.target" ];

      startLimitIntervalSec = 60;
      startLimitBurst = 5;

      serviceConfig = {
        User = user;
        Group = "users";
        SupplementaryGroups = [ "video" "render" "input" "uinput" ];

        PAMName = "gaming-kiosk";

        Environment = [
          "XDG_SEAT=seat-gaming"
          "XDG_SESSION_TYPE=wayland"
          "XDG_SESSION_CLASS=user"
          "LIBSEAT_BACKEND=logind"

          "XDG_RUNTIME_DIR=/run/user/%U"
          "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%U/bus"
          "PULSE_SERVER=unix:/run/user/%U/pulse/native"

          "WLR_LIBINPUT_NO_DEVICES=1"

          "WLR_DRM_DEVICES=/dev/dri/by-path/pci-0000:01:00.0-card"
          "VK_ICD_FILENAMES=/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.x86_64.json"
          "LIBVA_DRIVER_NAME=nvidia"
          "__GLX_VENDOR_LIBRARY_NAME=nvidia"
          "GBM_BACKEND=nvidia-drm"
        ];

        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        NoNewPrivileges = true;
        RestrictNamespaces = false;

        LimitCORE = "infinity";

        Restart = "always";
        RestartSec = 2;

        # Create wayland-0 -> gamescope-0 if wayland-0 doesn't already exist.
        # This is what makes Flatpak Steam able to connect to gamescope for PipeWire capture.
        ExecStartPre = pkgs.writeShellScript "gamescope-wayland-symlink" ''
          set -euo pipefail
          rt="/run/user/${toString config.users.users.${user}.uid}"
          if [ -S "$rt/wayland-0" ]; then
            # If something already owns wayland-0, don't clobber it.
            exit 0
          fi
          if [ -S "$rt/gamescope-0" ]; then
            ln -sf "$rt/gamescope-0" "$rt/wayland-0"
          fi
        '';

        ExecStopPost = pkgs.writeShellScript "gamescope-wayland-symlink-clean" ''
          set -euo pipefail
          rt="/run/user/${toString config.users.users.${user}.uid}"
          if [ -L "$rt/wayland-0" ]; then
            rm -f "$rt/wayland-0"
          fi
        '';

        ExecStart = ''
          ${pkgs.gamescope}/bin/gamescope \
            --backend drm \
            --prefer-vk-device 10de:1b80 \
            -O HDMI-A-3 \
            -W 2560 -H 1440 -r 120 \
            --xwayland-count 1 \
            -- ${steamLoop}
        '';
      };
    };
  };
}
