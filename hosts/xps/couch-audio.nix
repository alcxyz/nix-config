{...}: {
  # The Intel HDA controller exposes one PCM per physical display path. Keep
  # them simultaneous so DMS and the couch shortcuts can select an output
  # without changing the whole card profile first.
  services.pipewire.wireplumber.extraConfig."51-xps-couch-audio" = {
    "monitor.alsa.rules" = [
      {
        matches = [
          {
            "device.name" = "~alsa_card.pci-.*";
            "api.alsa.card.name" = "HDA Intel PCH";
          }
        ];
        actions."update-props" = {
          "api.alsa.use-acp" = false;
          "device.profile" = "pro-audio";
          "api.acp.auto-profile" = false;
          "api.acp.auto-port" = false;
        };
      }
      {
        matches = [{"node.name" = "~alsa_output.*[.]playback[.](0|3|7|8)[.]0";}];
        actions."update-props" = {
          # The pro-audio profile exposes every HDMI PCM concurrently, but its
          # generic 64-channel default is invalid for these stereo endpoints
          # and can wedge the graph while display routes are recreated.
          "audio.channels" = 2;
          "audio.position" = [
            "FL"
            "FR"
          ];
        };
      }
      {
        matches = [{"node.name" = "~alsa_input.*[.]capture[.]0[.]0";}];
        actions."update-props" = {
          "audio.channels" = 2;
          "audio.position" = [
            "FL"
            "FR"
          ];
        };
      }
      {
        matches = [{"node.name" = "~alsa_output.*[.]playback[.]0[.]0";}];
        actions."update-props" = {
          "node.description" = "XPS speakers";
          "node.nick" = "XPS speakers";
          "priority.session" = 900;
        };
      }
      {
        matches = [{"node.name" = "~alsa_output.*[.]playback[.]3[.]0";}];
        actions."update-props" = {
          "node.description" = "Auxiliary display";
          "node.nick" = "Auxiliary display";
          "priority.session" = 1000;
        };
      }
      {
        matches = [{"node.name" = "~alsa_output.*[.]playback[.]7[.]0";}];
        actions."update-props" = {
          "node.description" = "Secondary TV";
          "node.nick" = "Secondary TV";
          "priority.session" = 1200;
        };
      }
      {
        matches = [{"node.name" = "~alsa_output.*[.]playback[.]8[.]0";}];
        actions."update-props" = {
          "node.description" = "Primary TV";
          "node.nick" = "Primary TV";
          "priority.session" = 1100;
        };
      }
    ];
    "monitor.bluez.rules" = [
      {
        matches = [{"device.form-factor" = "speaker";}];
        actions."update-props"."device.profile" = "a2dp-sink";
      }
    ];
  };

  # Present the two TV paths as one optional stereo sink. PipeWire keeps a
  # playback stream connected to each physical sink and compensates for their
  # latency difference; selecting either physical sink remains possible.
  services.pipewire.extraConfig.pipewire."52-xps-dual-tv-output" = {
    "context.modules" = [
      {
        name = "libpipewire-module-combine-stream";
        args = {
          "combine.mode" = "sink";
          "node.name" = "xps_dual_tv";
          "node.description" = "Both TVs";
          "combine.latency-compensate" = true;
          "combine.props" = {
            "audio.position" = [
              "FL"
              "FR"
            ];
            "node.virtual" = true;
            # Keep it immediately after Primary TV in the couch audio cycle,
            # while leaving physical TV sinks ahead for fresh-session defaults.
            "priority.session" = 1050;
            # PipeWire stores linear amplitude; 0.064 is 40% on its cubic
            # user-facing volume scale.
            "state.default-volume" = "0.064";
          };
          "stream.props" = {};
          "stream.rules" = [
            {
              matches = [
                {
                  "media.class" = "Audio/Sink";
                  "node.name" = "~alsa_output.*[.]playback[.](7|8)[.]0";
                }
              ];
              actions."create-stream" = {
                "combine.audio.position" = [
                  "FL"
                  "FR"
                ];
                "audio.position" = [
                  "FL"
                  "FR"
                ];
              };
            }
          ];
        };
      }
    ];
  };
}
