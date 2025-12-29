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

  mkFlatpakDetached = name: appId: extraArgs:
    pkgs.writeShellScript "sunshine-launch-${name}" ''
      set -euo pipefail

      uid="$(${pkgs.coreutils}/bin/id -u)"
      sock="/run/user/$uid/gaming-wm/sway-gaming.sock"

      # Build the exact command we want Sway to run
      cmd="${
        lib.escapeShellArg
        (lib.concatStringsSep " " ([
            "${pkgs.flatpak}/bin/flatpak"
            "run"
            "--filesystem=xdg-run/gaming-wm"
            "--env=WAYLAND_DISPLAY=gaming-wm/wayland-1"
            "--env=__NV_PRIME_RENDER_OFFLOAD=1"
            "--env=__GLX_VENDOR_LIBRARY_NAME=nvidia"
            "--env=__VK_LAYER_NV_optimus=NVIDIA_only"
            "--env=PULSE_SINK=GameAudioSink"
            appId
          ]
          ++ extraArgs))
      }"

      exec ${pkgs.sway}/bin/swaymsg -s "$sock" exec "$cmd"
    '';

  steamScript = mkFlatpakDetached "steam-bp" "com.valvesoftware.Steam" [
    "-gamepadui"
  ];

  retrodeckScript =
    mkFlatpakDetached "retrodeck" "net.retrodeck.retrodeck" [ ];

  heroicScript =
    mkFlatpakDetached "heroic" "com.heroicgameslauncher.hgl" [ ];

  lutrisScript = mkFlatpakDetached "lutris" "net.lutris.Lutris" [ ];

  appsJsonText = builtins.toJSON {
    env = {
      PATH = "$(PATH):$(HOME)/.local/bin";
    };

    apps = [
      # IMPORTANT: keep this exact "Desktop" entry. Moonlight expects it.
      {
        name = "Desktop";
        "image-path" = "desktop.png";
        "prep-cmd" = [{ do = "${resizeScript}"; undo = ""; }];
      }

      {
        name = "Steam Big Picture";
        "image-path" = "steam.png";
        detached = [ "${steamScript}" ];
        "prep-cmd" = [{ do = "${resizeScript}"; undo = ""; }];
      }

      {
        name = "RetroDECK";
        detached = [ "${retrodeckScript}" ];
        "prep-cmd" = [{ do = "${resizeScript}"; undo = ""; }];
      }

      {
        name = "Heroic";
        detached = [ "${heroicScript}" ];
        "prep-cmd" = [{ do = "${resizeScript}"; undo = ""; }];
      }

      {
        name = "Lutris";
        detached = [ "${lutrisScript}" ];
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

    xdg.configFile."sunshine/sunshine.conf".text = sunshineConf;

    # Make apps.json a real writable file (not a /nix/store symlink)
    home.activation.sunshineAppsJson = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      set -euo pipefail
      dir="$HOME/.config/sunshine"
      target="$dir/apps.json"

      ${pkgs.coreutils}/bin/mkdir -p "$dir"
      ${pkgs.coreutils}/bin/rm -f "$target"
      ${pkgs.coreutils}/bin/install -m 0644 ${appsJsonFile} "$target"
    '';
  };
}
