# nix-config/modules/nixos/suites/gaming/sunshine.nix
{ config, lib, pkgs, username ? "alc", ... }:

let
  user = username;
  userHome = config.users.users.${user}.home or "/home/${user}";

  sunshineWrapped = "/run/wrappers/bin/sunshine-kiosk";

  resizeScript = pkgs.writeShellScript "sunshine-resize-headless" ''
    set -euo pipefail

    : "''${SWAYSOCK:?SWAYSOCK must be set}"

    w="''${SUNSHINE_CLIENT_WIDTH:-1920}"
    h="''${SUNSHINE_CLIENT_HEIGHT:-1080}"
    f="''${SUNSHINE_CLIENT_FPS:-60}"

    echo "$w" | ${pkgs.gnugrep}/bin/grep -Eq '^[0-9]+$' || w=1920
    echo "$h" | ${pkgs.gnugrep}/bin/grep -Eq '^[0-9]+$' || h=1080
    echo "$f" | ${pkgs.gnugrep}/bin/grep -Eq '^[0-9]+$' || f=60

    ${pkgs.sway}/bin/swaymsg -s "$SWAYSOCK" output HEADLESS-1 enable
    ${pkgs.sway}/bin/swaymsg -s "$SWAYSOCK" output HEADLESS-1 mode \
      "''${w}x''${h}@''${f}Hz"
  '';

  appsJson = pkgs.writeText "apps.json" (builtins.toJSON {
    apps = [
      {
        name = "Desktop (Headless)";
        cmd = "${pkgs.coreutils}/bin/sleep infinity";
        "prep-cmd" = [{ do = "${resizeScript}"; undo = ""; }];
      }
      {
        name = "Steam Big Picture";
        cmd = "${pkgs.flatpak}/bin/flatpak run com.valvesoftware.Steam -gamepadui";
        "prep-cmd" = [{ do = "${resizeScript}"; undo = ""; }];
      }
      {
        name = "RetroDECK";
        cmd = "${pkgs.flatpak}/bin/flatpak run net.retrodeck.retrodeck";
        "prep-cmd" = [{ do = "${resizeScript}"; undo = ""; }];
      }
      {
        name = "Heroic";
        cmd = "${pkgs.flatpak}/bin/flatpak run com.heroicgameslauncher.hgl";
        "prep-cmd" = [{ do = "${resizeScript}"; undo = ""; }];
      }
      {
        name = "Lutris";
        cmd = "${pkgs.flatpak}/bin/flatpak run net.lutris.Lutris";
        "prep-cmd" = [{ do = "${resizeScript}"; undo = ""; }];
      }
    ];
  });

  sunshineConf = pkgs.writeText "sunshine.conf" ''
    sunshine_name = xyz
    capture = wlr
    port = 47989
    min_log_level = debug
    system_tray = disabled

    # Explicitly point to the managed apps.json in ~/.config/sunshine
    file_apps = ${userHome}/.config/sunshine/apps.json

    audio_sink = GameAudioSink.monitor
  '';

  startSunshine = pkgs.writeShellScript "start-sunshine-gaming" ''
    set -euo pipefail
    exec ${sunshineWrapped} ${sunshineConf}
  '';
in
{
  config = lib.mkIf config.suites.gaming.enable {
    security.wrappers.sunshine-kiosk = {
      source = "${pkgs.sunshine}/bin/sunshine";
      owner = "root";
      group = "root";
      capabilities = "cap_sys_admin+ep";
    };

    # Force ~/.config/sunshine/apps.json to be OUR generated file.
    # Sunshine UI won't be able to edit apps (expected).
    systemd.tmpfiles.rules = [
      "d ${userHome}/.config/sunshine 0700 ${user} users - -"
      "L+ ${userHome}/.config/sunshine/apps.json - - - - ${appsJson}"
    ];

    networking.firewall.allowedTCPPorts = [ 47984 47989 47990 ];
    networking.firewall.allowedUDPPorts = [ 47998 47999 48000 48010 ];

    systemd.user.services.sunshine-kiosk = {
      description = "Sunshine (wlr capture from headless sway)";
      after = [ "gaming-wm.service" ];
      requires = [ "gaming-wm.service" ];
      wantedBy = [ "default.target" ];

      serviceConfig = {
        Type = "simple";

        # Keep your working env. If you already have these elsewhere, leave them.
        Environment = [
          "XDG_RUNTIME_DIR=%t"
          "WAYLAND_DISPLAY=gaming-wm/wayland-1"
          "SWAYSOCK=%t/gaming-wm/sway-gaming.sock"
          "PULSE_SERVER=unix:%t/pulse/native"
          "PIPEWIRE_REMOTE=pipewire-0"
        ];

        ExecStart = "${startSunshine}";

        Restart = "on-failure";
        RestartSec = 2;

        StandardOutput = "journal";
        StandardError = "journal";
      };
    };
  };
}
