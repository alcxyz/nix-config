# nix-config/modules/home-manager/suites/gaming/audio.nix
{ config, lib, pkgs, ... }:

{
  config = lib.mkIf config.suites.gaming.enable {
    # 1. Declarative Null Sink + Loopback
    # This file is placed in ~/.config/pipewire/pipewire.conf.d/
    xdg.configFile."pipewire/pipewire.conf.d/99-game-audio.conf".text = ''
      context.modules = [
        {
          name = libpipewire-module-null-sink
          args = {
            node.name = "GameAudioSink"
            node.description = "Game Audio Sink"
            media.class = "Audio/Sink"
            audio.position = [ FL FR ]
          }
        }
        {
          name = libpipewire-module-loopback
          args = {
            node.description = "Game Audio Loopback"
            capture.props = {
              node.target = "GameAudioSink"
              media.class = "Audio/Source"
            }
            playback.props = {
              node.name = "GameAudio_Loopback_Output"
              node.passive = true
              target.object = "@DEFAULT_SINK@"
            }
          }
        }
      ]
    '';

    # 2. WirePlumber Routing Rule
    xdg.configFile."wireplumber/wireplumber.conf.d/51-game-audio-routing.conf".text = builtins.toJSON {
      "monitor.pipewire.rules" = [
        {
          matches = [ 
            { "application.process.binary" = "~(steam|retrodeck|gamescope)"; } 
            { "app.id" = "~(com.valvesoftware.Steam|net.retrodeck.retrodeck)"; }
          ];
          actions.update-props = { "node.target" = "GameAudioSink"; };
        }
      ];
    };
  };
}
