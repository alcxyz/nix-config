# nix-config/modules/nixos/suites/gaming/audio.nix
{ config, lib, ... }:

let
  gameAppsRegex = "steam|steam_app_.*|retrodeck|retroarch|gamescope";
in {
  config = lib.mkIf config.suites.gaming.enable {
    services.pipewire = {
      extraConfig.pipewire."91-game-sink"."context.objects" = [{
        factory = "adapter";
        args = {
          "factory.name" = "support.null-audio-sink";
          "node.name" = "GameAudioSink";
          "node.description" = "Game Audio Sink";
          "media.class" = "Audio/Sink";
          "audio.position" = "FL,FR";
        };
      }];

      extraConfig.pipewire."92-game-loopback"."context.modules" = [{
        name = "libpipewire-module-loopback";
        args = {
          "node.description" = "Game Audio Loopback";
          "capture.props" = { "node.target" = "GameAudioSink"; "media.class" = "Audio/Source"; };
          "playback.props" = { "node.name" = "GameAudio_Loopback_Output"; "node.passive" = true; "target.object" = "@DEFAULT_SINK@"; };
        };
      }];

      wireplumber.extraConfig."51-game-audio-routing" = {
        "monitor.pipewire.rules" = [{
          matches = [
            { "application.process.binary" = "~(${gameAppsRegex})"; }
            { "app.id" = "~(com.valvesoftware.Steam|net.retrodeck.retrodeck)"; }
          ];
          actions.update-props = { "node.target" = "GameAudioSink"; };
        }];
      };
    };
  };
}
