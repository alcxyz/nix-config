# nix-config/modules/home-manager/suites/gaming/audio.nix
{ config, lib, pkgs, ... }:
let
  cfg = config.suites.gaming;
  gameAppsRegex = "steam|steamwebhelper|steam_app_.*|retrodeck|retroarch|dolphin-emu|pcsx2|rpcs3|duckstation|sunshine|gamescope";
in {
  config = lib.mkIf cfg.enable {
    home.packages = with pkgs; [ 
      socat 
      jq 
      pulseaudio 
      helvum 
    ];

    # 1. Virtual Sink Service
    systemd.user.services.game-audio-sink = {
      Unit = { Description = "Virtual Gaming Audio Sink"; After = [ "pipewire.service" ]; };
      Service = {
        Type = "oneshot";
        ExecStart = "${pkgs.pulseaudio}/bin/pactl load-module module-null-sink sink_name=GameAudioSink sink_properties='device.description=\"Virtual Game Sink\"'";
        RemainAfterExit = true;
      };
      Install.WantedBy = [ "default.target" ];
    };

    # 2. WirePlumber Routing
    xdg.configFile."wireplumber/wireplumber.conf.d/51-game-audio-routing.conf".text = builtins.toJSON {
      "monitor.pipewire.rules" = [
        {
          matches = [ { "application.process.binary" = "~(${gameAppsRegex})"; } ];
          actions.update-props = { "node.target" = "GameAudioSink"; };
        }
      ];
    };

    # 3. Audio Monitor Service
    systemd.user.services.workspace-audio-monitor = {
      Unit = { 
        Description = "Game Audio Loopback Toggle"; 
        After = [ "graphical-session.target" "game-audio-sink.service" ]; 
      };
      Service = {
        ExecStart = pkgs.writeShellScript "audio-monitor" ''
          SOCKET_PATH="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"
          while [ ! -S "$SOCKET_PATH" ]; do sleep 1; done

          # Inside nix-config/modules/home-manager/suites/gaming/audio.nix

          handle_audio() {
            focused_ws=$(hyprctl monitors -j | ${pkgs.jq}/bin/jq -r '.[] | select(.focused == true) | .activeWorkspace.id')
            
            if [ "$focused_ws" == "${cfg.gamingWorkspace}" ]; then
              # GUARD: Only load if NOT already loaded
              if ! pactl list short modules | grep -q "media.name=GameLoopback"; then
                ${pkgs.pulseaudio}/bin/pactl load-module module-loopback \
                  source="GameAudioSink.monitor" \
                  sink="@DEFAULT_SINK@" \
                  media.name="GameLoopback"
              fi
            else
              # Remove all instances matching our name
              while mod_id=$(pactl list short modules | grep "GameLoopback" | cut -f1 | head -n 1) && [ -n "$mod_id" ]; do
                ${pkgs.pulseaudio}/bin/pactl unload-module "$mod_id"
              done
            fi
          }

          ${pkgs.socat}/bin/socat -u UNIX-CONNECT:"$SOCKET_PATH" - | while read -r line; do
            case "$line" in 
              "workspace>>"*) handle_audio ;; 
              "focusedmon>>"*) handle_audio ;; 
            esac
          done
        '';
        Restart = "always";
        RestartSec = "5s";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
