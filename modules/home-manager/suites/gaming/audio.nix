# nix-config/modules/home-manager/suites/gaming/default.nix
{ config, lib, pkgs, ... }:
let
  # Regex matching Flatpak-based game processes and RetroDECK emulators
  gameAppsRegex = "steam|steamwebhelper|steam_app_.*|retrodeck|retroarch|dolphin-emu|pcsx2|rpcs3|duckstation|sunshine";
  gamingWorkspace = "9"; # The workspace on your HDMI Dongle
in {
  home.packages = with pkgs; [ socat jq pulseaudio ];

  # 1. WirePlumber Rules: Route all matching processes to the Virtual Sink
  xdg.configFile."wireplumber/wireplumber.conf.d/51-game-audio-routing.conf".text = ''
    monitor.pipewire.rules = [
      {
        matches = [
          { "application.process.binary" = "~(${gameAppsRegex})" }
        ]
        actions = {
          update-props = { "node.target" = "GameAudioSink" }
        }
      }
    ]
  '';

  # 2. Virtual Sink Service
  systemd.user.services.game-audio-sink = {
    Unit = {
      Description = "Create Virtual Gaming Audio Sink";
      After = [ "pipewire.service" ];
    };
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.pulseaudio}/bin/pactl load-module module-null-sink sink_name=GameAudioSink sink_properties='device.description=\"Virtual Game Sink\"'";
      RemainAfterExit = true;
    };
    Install.WantedBy = [ "default.target" ];
  };

  # 3. Workspace Audio Monitor (Hyprland Listener)
  systemd.user.services.workspace-audio-monitor = {
    Unit = {
      Description = "Toggle Game Audio Loopback on Workspace Focus";
      After = [ "graphical-session.target" ];
    };
    Service = {
      ExecStart = pkgs.writeShellScript "workspace-audio-logic" ''
        SOCKET_PATH="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

        handle_audio() {
            # Check which workspace is focused on the active monitor
            local focused_ws=$(hyprctl monitors -j | ${pkgs.jq}/bin/jq -r '.[] | select(.focused == true) | .activeWorkspace.id')
            
            if [ "$focused_ws" == "${gamingWorkspace}" ]; then
                # Enable local monitoring so you can hear the game when looking at the monitor
                ${pkgs.pulseaudio}/bin/pactl load-module module-loopback \
                    source="GameAudioSink.monitor" \
                    sink="@DEFAULT_SINK@" \
                    source_dont_move=true \
                    sink_dont_move=true \
                    media.name="GameLoopback"
            else
                # Disable local monitoring so audio only goes to the stream
                local mod_id=$(${pkgs.pulseaudio}/bin/pactl list short modules | grep "GameLoopback" | cut -f1)
                [ -n "$mod_id" ] && ${pkgs.pulseaudio}/bin/pactl unload-module "$mod_id"
            fi
        }

        # Listen to Hyprland events
        ${pkgs.socat}/bin/socat -u UNIX-CONNECT:"$SOCKET_PATH" - | while read -r line; do
            case "$line" in
                workspace>>*|focusedmon>>*) handle_audio ;;
            esac
        done
      '';
      Restart = "always";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
