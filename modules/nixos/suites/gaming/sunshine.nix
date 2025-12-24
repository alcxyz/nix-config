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
      autoStart = true;
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

    # Don't enable at boot (you can still `systemctl start sunshine`)
    systemd.services.sunshine.wantedBy = lib.mkForce [ ];

    systemd.services.sunshine.serviceConfig = {
      User = "alc";
      PAMName = "sunshine-kiosk";
      Environment = [
        "XDG_SEAT=seat-gaming"
        "XDG_SESSION_TYPE=wayland"
        "XDG_SESSION_CLASS=user"
        "XDG_RUNTIME_DIR=/run/user/%U"
        "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%U/bus"
        "PULSE_SERVER=unix:/run/user/%U/pulse/native"
      ];
    };



  };
}
