# modules/home-manager/suites/gaming/default.nix
{ options, config, lib, pkgs, ... }:

with lib;
let
  cfg = config.suites.gaming;

  # Gamescope launcher scripts using separate files
  gamescope-steam = pkgs.writeShellScript "gamescope-steam" 
    (builtins.readFile ./scripts/gamescope-steam.sh);

  gamescope-emulationstation = pkgs.writeShellScript "gamescope-emulationstation" 
    (builtins.readFile ./scripts/gamescope-emulationstation.sh);

  gamescope-browser = pkgs.writeShellScript "gamescope-browser" 
    (builtins.readFile ./scripts/gamescope-browser.sh);

in
{
  options.suites.gaming = with types; {
    enable = mkOption { 
      type = bool; 
      default = false; 
      description = "Enable the gaming suite configurations for this user."; 
    };
    
    gamingWorkspace = mkOption { 
      type = str; 
      default = "9"; 
      description = "The Hyprland workspace number for gaming."; 
    };
    
    hostBypassApps = mkOption {
      type = listOf str;
      default = [ "zen" "brave" "firefox" "chromium" "spotify" "discord" "vlc" ];
      description = "List of application process binary REGEX patterns that should always play audio on the host's physical speakers.";
    };
    
    gameApps = mkOption {
      type = listOf str;
      default = [ "steam" "steamwebhelper" "steam_app_.*" "retroarch" ".*\\.bin\\.x86_64" "dolphin-emu" "pcsx2" "emulationstation-de" "es-de" ];
      description = "List of application process binary REGEX patterns for game applications.";
    };
  };

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
      
      # Workspace audio monitor (standalone script, no service)
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

    # Keep the simple game sink service (this one works)
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

  };

}
