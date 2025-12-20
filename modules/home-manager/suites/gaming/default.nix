# nix-config/modules/home-manager/suites/gaming/default.nix
{ config, lib, pkgs, ... }:
let
  cfg = config.suites.gaming;
  gameAppsRegex = "steam|steamwebhelper|steam_app_.*|retrodeck|retroarch|dolphin-emu|pcsx2|rpcs3|sunshine|gamescope";
in {
  options.suites.gaming = {
    enable = lib.mkEnableOption "Gaming Suite";
    gamingWorkspace = lib.mkOption { 
      type = lib.types.str; 
      default = "9"; 
    };
  };

  config = lib.mkIf cfg.enable {
    # Scripts added to your PATH
    home.packages = with pkgs; [
      socat jq pulseaudio gamescope mangohud
      
      # Launcher for Sunshine to call
      (writeShellScriptBin "launch-steam" ''
        gamescope -W 2560 -H 1440 -r 60 -f -b -- flatpak run com.valvesoftware.Steam -bigpicture
      '')

      (writeShellScriptBin "launch-retrodeck" ''
        gamescope -W 1920 -H 1080 -r 60 -f -b -- flatpak run net.retrodeck.retrodeck
      '')
    ];

    # Audio Routing Rules
    xdg.configFile."wireplumber/wireplumber.conf.d/51-game-audio-routing.conf".text = builtins.toJSON {
      "monitor.pipewire.rules" = [
        {
          matches = [ { "application.process.binary" = "~(${gameAppsRegex})"; } ];
          actions.update-props = { "node.target" = "GameAudioSink"; };
        }
      ];
    };

    # Virtual Sink
    systemd.user.services.game-audio-sink = {
      Unit = { Description = "Virtual Gaming Audio Sink"; After = [ "pipewire.service" ]; };
      Service = {
        Type = "oneshot";
        ExecStart = "${pkgs.pulseaudio}/bin/pactl load-module module-null-sink sink_name=GameAudioSink sink_properties='device.description=\"Virtual Game Sink\"'";
        RemainAfterExit = true;
      };
      Install.WantedBy = [ "default.target" ];
    };

    # Audio Monitor Logic
    systemd.user.services.workspace-audio-monitor = {
      Unit = { Description = "Game Audio Loopback Toggle"; After = [ "graphical-session.target" ]; };
      Service = {
        ExecStart = pkgs.writeShellScript "audio-monitor" ''
          SOCKET_PATH="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
          
          # Wait for socket
          while [ ! -S "$SOCKET_PATH" ]; do sleep 1; done

          handle_audio() {
            focused_ws=$(hyprctl monitors -j | ${pkgs.jq}/bin/jq -r '.[] | select(.focused == true) | .activeWorkspace.id')
            if [ "$focused_ws" == "${cfg.gamingWorkspace}" ]; then
              ${pkgs.pulseaudio}/bin/pactl load-module module-loopback source="GameAudioSink.monitor" sink="@DEFAULT_SINK@" media.name="GameLoopback"
            else
              mod_id=$(${pkgs.pulseaudio}/bin/pactl list short modules | grep "GameLoopback" | cut -f1)
              [ -n "$mod_id" ] && ${pkgs.pulseaudio}/bin/pactl unload-module "$mod_id"
            fi
          }

          ${pkgs.socat}/bin/socat -u UNIX-CONNECT:"$SOCKET_PATH" - | while read -r line; do
            case "$line" in workspace>>*|focusedmon>>*) handle_audio ;; esac
          done
        '';
        Restart = "always";
        RestartSec = "5s";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
