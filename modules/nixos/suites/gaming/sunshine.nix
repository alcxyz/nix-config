{ config, lib, pkgs, username ? "alc", ... }:

let
  user = username;
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
      # Keep Sunshine from launching Steam; Steam is already running in the kiosk.
      { name = "Kiosk"; cmd = "${pkgs.coreutils}/bin/sleep infinity"; }
    ];
  });

  sunshineConf = pkgs.writeText "sunshine.conf" ''
    sunshine_name = xyz
    capture = wlroots
    encoder = nvenc
    audio_sink = GameAudioSink.monitor
    file_apps = ${appsJson}
    port = 47989
  '';
in
{
  config = lib.mkIf config.suites.gaming.enable {
    # Do NOT run Sunshine as a user unit (it will attach to your Hyprland display).
    systemd.user.services.sunshine.enable = lib.mkForce false;

    systemd.services.sunshine-kiosk = {
      description = "Sunshine (wlroots capture from gamescope, seat-gaming)";
      after = [ "systemd-logind.service" "network-online.target" "gaming-kiosk.service" ];
      wants = [ "network-online.target" "gaming-kiosk.service" ];
      requires = [ "systemd-logind.service" ];

      # manual start by default
      wantedBy = [ ];

      serviceConfig = {
        User = user;
        Group = "users";
        SupplementaryGroups = [ "video" "render" "input" "uinput" ];

        PAMName = "sunshine-kiosk";

        Environment = [
          "XDG_SEAT=seat-gaming"
          "XDG_SESSION_TYPE=wayland"
          "XDG_SESSION_CLASS=user"

          # IMPORTANT: talk to gamescope, not Hyprland
          "XDG_RUNTIME_DIR=/run/user/%U"
          "WAYLAND_DISPLAY=gamescope-0"
          "PIPEWIRE_REMOTE=pipewire-0"
          "PULSE_SERVER=unix:/run/user/%U/pulse/native"
        ];

        # No CAP_SYS_ADMIN needed for wlroots capture.
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        NoNewPrivileges = true;
        RestrictNamespaces = false;

        ExecStart = "${sunshinePatched}/bin/sunshine ${sunshineConf}";
        Restart = "on-failure";
        RestartSec = 2;
      };
    };
  };
}
