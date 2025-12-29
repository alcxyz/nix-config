# nix-config/modules/nixos/suites/gaming/audio.nix
{ config, lib, ... }:

let
  gameAppsRegex =
    "steam|steam_app_.*|retrodeck|retroarch|gamescope|lutris|heroic";
in
{
  options.suites.gaming.audio = {
    monitorLocally = lib.mkEnableOption "Also play game audio locally (disable for kiosk)";
  };

  config = lib.mkIf config.suites.gaming.enable {
    services.pipewire = {
      # Virtual sink: games go here; it's silent locally, but has a monitor source.
      extraConfig.pipewire."91-game-sink"."context.objects" = [
        {
          factory = "adapter";
          args = {
            "factory.name" = "support.null-audio-sink";
            "node.name" = "GameAudioSink";
            "node.description" = "Game Audio Sink (Stream Only)";
            "media.class" = "Audio/Sink";
            "audio.position" = "FL,FR";
          };
        }
      ];

      # OPTIONAL: if enabled, mirror GameAudioSink.monitor -> your default speakers
      extraConfig.pipewire."92-game-loopback" = lib.mkIf config.suites.gaming.audio.monitorLocally {
        "context.modules" = [
          {
            name = "libpipewire-module-loopback";
            args = {
              "node.description" = "Game Audio -> Local Speakers";
              "capture.props" = {
                # monitor source of the sink
                "node.target" = "GameAudioSink.monitor";
                "media.class" = "Audio/Source";
              };
              "playback.props" = {
                "node.name" = "GameAudio_Loopback_Output";
                "node.passive" = true;
                "target.object" = "@DEFAULT_SINK@";
              };
            };
          }
        ];
      };

      # Route matching apps to GameAudioSink
      wireplumber.extraConfig."51-game-audio-routing" = {
        "monitor.pipewire.rules" = [
          {
            matches = [
              { "application.process.binary" = "~(${gameAppsRegex})"; }
              {
                "app.id" =
                  "~(com.valvesoftware.Steam|net.retrodeck.retrodeck|net.lutris.Lutris|com.heroicgameslauncher.hgl)";
              }
            ];
            actions.update-props = {
              "node.target" = "GameAudioSink";
            };
          }
        ];
      };

      wireplumber.extraConfig."52-demote-sunshine-sink" = {
        "monitor.pipewire.rules" = [
          {
            matches = [
              { "node.name" = "sink-sunshine-stereo"; }
            ];
            actions.update-props = {
              "priority.session" = 1;
              "priority.driver" = 1;
            };
          }
        ];
      };

    };
  };
}
