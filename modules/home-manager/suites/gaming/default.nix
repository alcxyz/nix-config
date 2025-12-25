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

  flatpakNvidia = appId: extraArgs:
    lib.concatStringsSep " " ([
      "${pkgs.flatpak}/bin/flatpak"
      "run"
      "--env=__NV_PRIME_RENDER_OFFLOAD=1"
      "--env=__GLX_VENDOR_LIBRARY_NAME=nvidia"
      "--env=__VK_LAYER_NV_optimus=NVIDIA_only"
      "--env=PULSE_SINK=GameAudioSink"
      appId
    ] ++ extraArgs);

  appsJsonText = builtins.toJSON {
    apps = [
      {
        name = "Desktop (Headless)";
        cmd = "${pkgs.coreutils}/bin/sleep infinity";
        "prep-cmd" = [{ do = "${resizeScript}"; undo = ""; }];
      }
      {
        name = "Steam Big Picture";
        cmd = flatpakNvidia "com.valvesoftware.Steam" [ "-gamepadui" ];
        "prep-cmd" = [{ do = "${resizeScript}"; undo = ""; }];
      }
      {
        name = "RetroDECK";
        cmd = flatpakNvidia "net.retrodeck.retrodeck" [ ];
        "prep-cmd" = [{ do = "${resizeScript}"; undo = ""; }];
      }
      {
        name = "Heroic";
        cmd = flatpakNvidia "com.heroicgameslauncher.hgl" [ ];
        "prep-cmd" = [{ do = "${resizeScript}"; undo = ""; }];
      }
      {
        name = "Lutris";
        cmd = flatpakNvidia "net.lutris.Lutris" [ ];
        "prep-cmd" = [{ do = "${resizeScript}"; undo = ""; }];
      }
    ];
  };

  appsJsonFile = pkgs.writeText "sunshine-apps.json" appsJsonText;

  sunshineConf = ''
    sunshine_name = xyz
    capture = wlr
    port = 47989
    encoder = vaapi

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

    # Keep sunshine.conf HM-managed (read-only is fine here)
    xdg.configFile."sunshine/sunshine.conf".text = sunshineConf;

    # Make apps.json a *real writable file*, not a /nix/store symlink
    home.activation.sunshineAppsJson = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      set -euo pipefail
      dir="$HOME/.config/sunshine"
      target="$dir/apps.json"

      ${pkgs.coreutils}/bin/mkdir -p "$dir"

      # Replace HM symlink with a real file
      if [ -L "$target" ]; then
        ${pkgs.coreutils}/bin/rm -f "$target"
      fi

      ${pkgs.coreutils}/bin/install -m 0644 ${appsJsonFile} "$target"

      # Ensure Sunshine can write updates if it wants
      ${pkgs.coreutils}/bin/chmod u+w "$target"
    '';
  };
}
