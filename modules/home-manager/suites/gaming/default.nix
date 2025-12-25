# nix-config/modules/home-manager/suites/gaming/default.nix
{ config, lib, pkgs, ... }:

let
  cfg = config.suites.gaming;

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

  appsJson = builtins.toJSON {
    apps = [
      {
        name = "Desktop (Headless)";
        cmd = "${pkgs.coreutils}/bin/sleep infinity";
        "prep-cmd" = [{ do = "${resizeScript}"; undo = ""; }];
      }
      {
        name = "Steam Big Picture";
        cmd =
          "${pkgs.flatpak}/bin/flatpak run com.valvesoftware.Steam -gamepadui";
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
  };

  sunshineConf = ''
    sunshine_name = xyz
    capture = wlr
    port = 47989

    # Make this actually visible in logs if it's being read:
    min_log_level = info
    system_tray = enabled

    file_apps = apps.json
    audio_sink = GameAudioSink.monitor
  '';
in
{
  options.suites.gaming.enable = lib.mkEnableOption "Gaming HM Suite";

  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [
      gamescope
      mangohud
      helvum
    ];

    xdg.configFile."sunshine/sunshine.conf".text = sunshineConf;
    xdg.configFile."sunshine/apps.json".text = appsJson;
  };
}
