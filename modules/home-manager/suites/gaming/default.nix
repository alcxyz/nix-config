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
      
      # Workspace audio monitor
      (pkgs.writeShellScriptBin "workspace-audio-monitor" 
        (builtins.readFile ./scripts/monitor-workspace-audio.sh))
    ];

    # WirePlumber auto-routing rules
    xdg.configFile."wireplumber/wireplumber.conf.d/51-game-audio-routing.conf" = {
      text = builtins.toJSON {
        "monitor.pipewire.rules" = [
          # Route game applications to GameAudioSink
          {
            matches = [
              { "application.process.binary" = "~(${concatStringsSep "|" cfg.gameApps})"; }
            ];
            actions.update-props = {
              "node.target" = "GameAudioSink";
            };
          }
          # Keep host applications on default sink (explicit rule for clarity)
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

    # Start workspace audio monitor with session
    systemd.user.services.workspace-audio-monitor = {
      Unit = {
        Description = "Monitor workspace changes for game audio";
        After = [ "graphical-session.target" "pipewire-game-sink.service" ];
        Wants = [ "pipewire-game-sink.service" ];
        PartOf = [ "graphical-session.target" ];
      };
      
      Service = {
        Type = "simple";
        ExecStart = "${pkgs.writeShellScript "workspace-audio-monitor" (builtins.readFile ./scripts/monitor-workspace-audio.sh)}";
        Restart = "on-failure";
        RestartSec = "5s";
        # Add startup delay to ensure everything is ready
        ExecStartPre = "${pkgs.coreutils}/bin/sleep 5";
        Environment = [
          "GAMING_WORKSPACE=${cfg.gamingWorkspace}"
        ];
      };
      
      Install.WantedBy = [ "graphical-session.target" ];
    };

  };
}
