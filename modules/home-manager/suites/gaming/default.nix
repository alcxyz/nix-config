# modules/home-manager/suites/gaming/default.nix
{ options, config, lib, pkgs, ... }:

with lib;
let
  cfg = config.suites.gaming;
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
      default = "1"; 
      description = "The Hyprland workspace number for gaming."; 
    };
    
    hostBypassApps = mkOption {
      type = listOf str;
      default = [ "zen" "brave" "firefox" "spotify" "discord" "vlc" ];
      description = "List of application process binary REGEX patterns that should always play audio on the host's physical speakers.";
    };
    
    gameApps = mkOption {
      type = listOf str;
      default = [ "steam" "steamwebhelper" "steam_app_.*" "retroarch" ".*\\.bin\\.x86_64" "dolphin-emu" "pcsx2" "emulationstation-de" "es-de" "gamescope" ];
      description = "List of application process binary REGEX patterns for game applications.";
    };
  };

  # modules/home-manager/suites/gaming/default.nix
  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      # Gaming applications
      gamescope
      mangohud
      vulkan-tools
      wayland-utils
      socat  # Required for socket monitoring
      
      # Ensure game sink script
      (pkgs.writeShellScriptBin "ensure-game-sink" 
        (builtins.readFile ./scripts/ensure-game-sink.sh))
      
      # Manual audio management script (for debugging)
      (pkgs.writeShellScriptBin "manage-game-audio" ''
        #!/usr/bin/env bash
        set -euo pipefail

        SINK_NAME="GameAudioSink"
        LOOPBACK_NAME="GameAudioLoopback"
        GAMING_WORKSPACE="${cfg.gamingWorkspace}"

        ${builtins.readFile ./scripts/manage-game-audio.sh}
      '')
      
      # Workspace audio monitor - inject the gaming workspace value
      (pkgs.writeShellScriptBin "workspace-audio-monitor" ''
        #!/usr/bin/env bash
        set -euo pipefail

        SCRIPT_NAME="workspace-audio-monitor"
        SINK_NAME="GameAudioSink"
        GAMING_WORKSPACE="${cfg.gamingWorkspace}"
        SOCKET_PATH="$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock"

        ${builtins.readFile ./scripts/workspace-audio-monitor.sh}
      '')
      
      (pkgs.writeShellScriptBin "gamescope-steam" 
        (builtins.readFile ./scripts/gamescope-steam.sh))

      (pkgs.writeShellScriptBin "gamescope-stream"
        (builtins.readFile ./scripts/gamescope-stream.sh))
      
      (pkgs.writeShellScriptBin "gamescope-emulationstation" 
        (builtins.readFile ./scripts/gamescope-emulationstation.sh))
      
      (pkgs.writeShellScriptBin "gamescope-browser" 
        (builtins.readFile ./scripts/gamescope-browser.sh))
    ];

    # Optional: Systemd user service for automatic startup
    systemd.user.services.workspace-audio-monitor = {
      Unit = {
        Description = "Workspace Audio Monitor for Gaming";
        After = [ "graphical-session.target" "pipewire.service" ];
        PartOf = [ "graphical-session.target" ];
      };
      
      Service = {
        Type = "simple";
        ExecStart = "${pkgs.writeShellScript "workspace-audio-monitor-service" ''
          # Wait for Hyprland to be ready
          while [[ -z "''${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || [[ ! -S "$XDG_RUNTIME_DIR/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock" ]]; do
            sleep 1
          done
          
          exec workspace-audio-monitor monitor
        ''}";
        Restart = "on-failure";
        RestartSec = "5s";
      };
      
      Install.WantedBy = [ "graphical-session.target" ];
    };

    # WirePlumber configuration (unchanged)
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
