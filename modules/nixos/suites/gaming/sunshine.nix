{ config, lib, pkgs, ... }:

let
  nvidiaLib = "${config.hardware.nvidia.package}/lib";

  sunshinePatched = pkgs.sunshine.overrideAttrs (old: {
    nativeBuildInputs = (old.nativeBuildInputs or []) ++ [pkgs.patchelf];
    postFixup =
      (old.postFixup or "")
      + ''
        patchelf --add-rpath "${nvidiaLib}" $out/bin/sunshine
      '';
  });

  appsJson = pkgs.writeText "sunshine-apps.json" (builtins.toJSON {
    apps = [
      {
        name = "Steam Deck";
        cmd = "flatpak run com.valvesoftware.Steam -gamepadui";
      }
      {
        name = "RetroDECK";
        cmd = "flatpak run net.retrodeck.retrodeck";
      }
      {
        name = "Heroic";
        cmd = "flatpak run com.heroicgameslauncher.hgl";
      }
    ];
  });

  sunshineConf = pkgs.writeText "sunshine.conf" ''
    sunshine_name = xyz
    capture = kms
    adapter_name = /dev/dri/by-path/pci-0000:01:00.0-card
    output_name = HDMI-A-3
    encoder = nvenc
    audio_sink = GameAudioSink.monitor
    file_apps = ${appsJson}
    port = 47989
  '';
in
{
  config = lib.mkIf config.suites.gaming.enable {
    # Ensure Sunshine can create virtual input devices later
    services.udev.extraRules = ''
      KERNEL=="uinput", SUBSYSTEM=="misc", MODE="0660", GROUP="input", TAG+="uaccess"
    '';

    # IMPORTANT: stop using the user unit (it binds Sunshine to your Hyprland/Wayland session)
    systemd.user.services.sunshine.enable = lib.mkForce false;

    systemd.services.sunshine-kiosk = {
      description = "Sunshine (seat-gaming, NVIDIA KMS HDMI-A-3)";
      after = [ "systemd-logind.service" "network-online.target" "gaming-kiosk.service" ];
      wants = [ "network-online.target" "gaming-kiosk.service" ];
      requires = [ "systemd-logind.service" ];

      # manual start by default (you can enable later)
      wantedBy = [ ];

      serviceConfig = {
        User = "alc";
        Group = "users";
        SupplementaryGroups = [ "video" "render" "input" ];

        PAMName = "sunshine-kiosk";

        Environment = [
          "PATH=/run/current-system/sw/bin:${pkgs.coreutils}/bin:${pkgs.flatpak}/bin"
          "XDG_SEAT=seat-gaming"
          "XDG_SESSION_TYPE=wayland"
          "XDG_SESSION_CLASS=user"
          "XDG_RUNTIME_DIR=/run/user/%U"
          "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%U/bus"
          "PULSE_SERVER=unix:/run/user/%U/pulse/native"
        ];

        # Sunshine needs KMS access -> CAP_SYS_ADMIN
        CapabilityBoundingSet = "CAP_SYS_ADMIN";
        AmbientCapabilities = "CAP_SYS_ADMIN";
        NoNewPrivileges = false;

        ExecStart = "${sunshinePatched}/bin/sunshine ${sunshineConf}";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };
  };
}
