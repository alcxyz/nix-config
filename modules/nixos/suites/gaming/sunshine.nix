# nix-config/modules/nixos/suites/gaming/sunshine.nix
{ config, lib, pkgs, ... }:

let
  nvidiaLib = "${config.hardware.nvidia.package}/lib";

  sunshinePatched = pkgs.sunshine.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkgs.patchelf ];
    postFixup =
      (old.postFixup or "")
      + ''
        patchelf --add-rpath "${nvidiaLib}" $out/bin/sunshine
      '';
  });
in {
  config = lib.mkIf config.suites.gaming.enable {
    services.sunshine = {
      enable = true;
      package = sunshinePatched;
      autoStart = false;
      capSysAdmin = true;
      settings = {
        sunshine_name = "xyz";
        audio_sink = "GameAudioSink.monitor";
        capture = "kms";
        adapter_name = "/dev/dri/by-path/pci-0000:01:00.0-card";
        output_name = "HDMI-A-3";
        encoder = "nvenc";
      };
      applications.apps = [
        {
          name = "Steam Deck";
          cmd = "gamescope-kiosk steam -gamepadui";
        }
        {
          name = "RetroDECK";
          cmd = "gamescope-kiosk flatpak run net.retrodeck.retrodeck";
        }
        {
          name = "Heroic";
          cmd = "gamescope-kiosk flatpak run com.heroicgameslauncher.hgl";
        }
      ];
    };

    systemd.user.services.sunshine = {
      requires = [ "gaming-kiosk-base.service" ];
      after = [ "gaming-kiosk-base.service" ];
      serviceConfig.Environment = lib.mkForce [
        "XDG_RUNTIME_DIR=/run/user/1000"
        "WAYLAND_DISPLAY=wayland-gaming" # Sunshine uses this for cursor tracking
        "LD_LIBRARY_PATH=/run/opengl-driver/lib:/run/opengl-driver-32/lib"
        "WLR_DRM_DEVICES=/dev/dri/by-path/pci-0000:01:00.0-card" # Point to NVIDIA
        "__GLX_VENDOR_LIBRARY_NAME=nvidia"
      ];
    };

  };
}
