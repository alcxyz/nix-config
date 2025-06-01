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

  # Audio management scripts using template substitution
  prepare-streaming-audio = pkgs.replaceVars ./scripts/prepare-streaming-audio.sh {
    gameApps = concatStringsSep "|" cfg.gameApps;
    hostBypassApps = concatStringsSep "|" cfg.hostBypassApps;
    inherit (pkgs) pulseaudio gnugrep gawk;
  };

  restore-default-audio = pkgs.replaceVars ./scripts/restore-default-audio.sh {
    gameApps = concatStringsSep "|" cfg.gameApps;
    inherit (pkgs) pulseaudio gnugrep gawk;
  };

  manage-game-audio-routing = pkgs.replaceVars ./scripts/manage-game-audio-routing.sh {
    gamingWorkspace = cfg.gamingWorkspace;
    gameApps = concatStringsSep "|" cfg.gameApps;
    inherit (pkgs) pulseaudio gnugrep gawk procps;
  };

  # WirePlumber rules for audio routing
  hostBypassWirePlumberRules = map (appPattern: {
    matches = [ { "application.process.binary" = "~${appPattern}"; } ]; 
    actions.update-props = { "node.target" = "@DEFAULT_SINK@"; };
  }) cfg.hostBypassApps;

  gameAppWirePlumberRules = map (appPattern: {
    matches = [ { "application.process.binary" = "~${appPattern}"; } ];
    actions.update-props = { "node.target" = "GameAudioSink"; };
  }) cfg.gameApps;

  wireplumberConfContent = {
    "monitor.alsa.rules" = [
      {
        matches = [ { "node.name" = "~alsa_output.*"; } ]; 
        actions.update-props = {
          "node.nick" = "Physical Speakers"; 
          "priority.driver" = 1000; 
        };
      }
    ];
    "monitor.pipewire.rules" = lib.mkIf (cfg.hostBypassApps != [] || cfg.gameApps != []) (
      hostBypassWirePlumberRules ++ gameAppWirePlumberRules
    );
  };

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
      default = [ "zen" "brave" "firefox" "chromium" "spotify" "discord" ];
      description = "List of application process binary REGEX patterns that should always play audio on the host's physical speakers.";
    };
    
    gameApps = mkOption {
      type = listOf str;
      default = [ "steamwebhelper" "steam_app_.*" "retroarch" ".*\\.bin\\.x86_64" "dolphin-emu" "pcsx2" "emulationstation-de" ];
      description = "List of application process binary REGEX patterns for game applications.";
    };
  };

  config = mkIf cfg.enable {
    home.packages = with pkgs; [
      # Gaming applications
      gamescope emulationstation-de retroarchFull dolphin-emu pcsx2 mangohud
      vulkan-tools
      wayland-utils
      
      # Gamescope launcher scripts
      (pkgs.writeShellScriptBin "gamescope-steam" ''exec ${gamescope-steam}'')
      (pkgs.writeShellScriptBin "gamescope-emulationstation" ''exec ${gamescope-emulationstation}'')
      (pkgs.writeShellScriptBin "gamescope-browser" ''exec ${gamescope-browser}'')
      
      # Audio management scripts
      (pkgs.writeShellScriptBin "prepare-streaming-audio" ''exec ${prepare-streaming-audio}'')
      (pkgs.writeShellScriptBin "restore-default-audio" ''exec ${restore-default-audio}'')
      (pkgs.writeShellScriptBin "manage-game-audio-routing" ''exec ${manage-game-audio-routing} "$@"'')
    ];

    # WirePlumber configuration for automatic audio routing
    xdg.configFile."wireplumber/wireplumber.conf.d/52-user-game-audio-routing.conf" = {
      text = pkgs.lib.generators.toJSON {} wireplumberConfContent;
    };
  };
}
