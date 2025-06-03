config = mkIf cfg.enable {
  home.packages = with pkgs; [
    # Gaming applications
    gamescope
    mangohud
    vulkan-tools
    wayland-utils
    
    # Gamescope launcher scripts
    (pkgs.writeShellScriptBin "gamescope-steam" ''exec ${gamescope-steam}'')
    (pkgs.writeShellScriptBin "gamescope-emulationstation" ''exec ${gamescope-emulationstation}'')
    (pkgs.writeShellScriptBin "gamescope-browser" ''exec ${gamescope-browser}'')
    
    # Workspace audio monitor
    (pkgs.writeShellScriptBin "workspace-audio-monitor" 
      (builtins.readFile ./scripts/monitor-workspace-audio.sh))
      
    # Game sink creation script
    (pkgs.writeShellScriptBin "ensure-game-sink" ''
      #!/usr/bin/env bash
      SINK_NAME="GameAudioSink"
      
      # Check if sink already exists
      if pactl list short sinks | grep -q "$SINK_NAME"; then
        exit 0
      fi
      
      # Create the sink
      if command -v pactl >/dev/null && pactl info >/dev/null 2>&1; then
        pactl load-module module-null-sink \
          sink_name="$SINK_NAME" \
          sink_properties="device.description='Virtual Sink for Games and Streaming'" \
          rate=48000 \
          channels=2 >/dev/null 2>&1
      fi
    '')
  ];

  # Create GameAudioSink at session start
  systemd.user.services.ensure-game-sink = {
    Unit = {
      Description = "Ensure GameAudioSink exists";
      After = [ "pipewire.service" "pipewire-pulse.service" ];
    };
    
    Service = {
      Type = "oneshot";
      ExecStart = "${pkgs.writeShellScript "ensure-game-sink" ''
        #!/usr/bin/env bash
        SINK_NAME="GameAudioSink"
        
        # Wait a moment for audio system
        sleep 2
        
        # Check if sink already exists
        if pactl list short sinks | grep -q "$SINK_NAME"; then
          echo "GameAudioSink already exists"
          exit 0
        fi
        
        # Create the sink
        if command -v pactl >/dev/null && pactl info >/dev/null 2>&1; then
          echo "Creating GameAudioSink"
          pactl load-module module-null-sink \
            sink_name="$SINK_NAME" \
            sink_properties="device.description='Virtual Sink for Games and Streaming'" \
            rate=48000 \
            channels=2
        fi
      ''}";
    };
    
    Install.WantedBy = [ "default.target" ];
  };

  # WirePlumber auto-routing rules (unchanged)
  xdg.configFile."wireplumber/wireplumber.conf.d/51-game-audio-routing.conf" = {
    text = builtins.toJSON {
      "monitor.pipewire.rules" = [
        {
          matches = [
            { "application.process.binary" = "~(${concatStringsSep "|" cfg.gameApps})"; }
          ];
          actions.update-props = {
            "node.target" = "GameAudioSink";
          };
        }
        {
          matches = [
            { "application.process.binary" = "~(${concatStringsSep "|" cfg.hostBypassApps})"; }
          ];
          actions.update-props = {
            "node.target" = "@DEFAULT_SINK@";
          };
        }
      ];
    };
  };

  # Start workspace audio monitor with session (updated dependencies)
  systemd.user.services.workspace-audio-monitor = {
    Unit = {
      Description = "Monitor workspace changes for game audio";
      After = [ "graphical-session.target" "ensure-game-sink.service" ];
      Wants = [ "ensure-game-sink.service" ];
      PartOf = [ "graphical-session.target" ];
    };
    
    Service = {
      Type = "simple";
      ExecStart = "${pkgs.writeShellScript "workspace-audio-monitor" (builtins.readFile ./scripts/monitor-workspace-audio.sh)}";
      Restart = "on-failure";
      RestartSec = "5s";
      Environment = [
        "GAMING_WORKSPACE=${cfg.gamingWorkspace}"
      ];
    };
    
    Install.WantedBy = [ "graphical-session.target" ];
  };
};
